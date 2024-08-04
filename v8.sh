#!/bin/bash

# Yapılandırma dosyasını oku
CONFIG_FILE="config.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Yapılandırma dosyası bulunamadı: $CONFIG_FILE"
    exit 1
fi

# Yapılandırma dosyasını oku ve değişkenleri ayarla
while IFS='=' read -r key value; do
    case "$key" in
        DATA_BW) DATA_BW="$value" ;;
        DATA_GW) DATA_GW="$value" ;;
        DATA_IP) DATA_IP="$value" ;;
        DATA_LACP) DATA_LACP="$value" ;;
        DATA_SLAVES) DATA_SLAVES=($value) ;;
    esac
done < "$CONFIG_FILE"

# UP olan NIC'leri listele
up_nics=$(ip link show | awk '/state UP/ {print $2}' | sed 's/://g' | grep -v 'lo')

# UP olan NIC'leri diziye dönüştür
IFS=$'\n' read -r -d '' -a nic_array < <(printf '%s\n' "$up_nics" && printf '\0')

# Bond oluşturma fonksiyonu
create_bond() {
    local bond_name=$1
    local ip=$2
    local gw=$3
    local lacp=$4
    shift 4
    local nics=("$@")
    
    # Önce mevcut bir bond varsa sil
    nmcli con show | grep -q "bond-$bond_name" && nmcli con delete "bond-$bond_name"
    
    # Bond'u oluştur ve nics ekle
    nmcli con add type bond con-name "bond-$bond_name"  ifname "bond-$bond_name"
    for nic in "${nics[@]}"; do
        nmcli con add type ethernet slave-type bond ifname "$nic" master "bond-$bond_name"
    done
    
    # LACP ayarlarını yap
    if [ "$lacp" == "evet" ]; then
        nmcli con mod "bond-$bond_name" bond.mode 802.3ad
    fi
    
    # IP ve GW ayarlarını yap
    nmcli con mod "bond-$bond_name" ipv4.addresses "$ip"
    if [ -n "$gw" ]; then
        nmcli con mod "bond-$bond_name" ipv4.gateway "$gw"
    fi
    nmcli con mod "bond-$bond_name" ipv4.method manual
    
    # Bond'u aktif et
    nmcli con up "bond-$bond_name"
}

# Bond'u test etme ve bant genişliği tutmazsa silme fonksiyonu
test_and_cleanup_bond() {
    local bond_name=$1
    local expected_bw=$2
    shift 2
    local nics=("$@")
    
    # 5 saniye bekle
    sleep 5
    
    # Etthool ile bant genişliğini kontrol et
    local bw=$(ethtool "$bond_name" | grep "Speed" | awk '{print $2}' | sed 's/Mb\/s//')
    
    if [[ "$bw" == "$expected_bw" ]]; then
        echo "Bond $bond_name başarıyla oluşturuldu ve bant genişliği doğru: $bw Mb/s"
        return 0
    else
        echo "Bond $bond_name başarısız, beklenen bant genişliği: ${expected_bw} Mb/s, mevcut: $bw Mb/s"
        
        # Bond ve slave'leri sil
        nmcli con down "$bond_name"
        nmcli con delete "$bond_name"
        for nic in "${nics[@]}"; do
            nmcli con delete $(nmcli -t -f UUID,DEVICE con | grep "$nic" | cut -d: -f1)
        done
        return 1
    fi
}

# Data Bond'u oluştur ve test et
for ((i = 0; i < ${#nic_array[@]} - 1; i++)); do
    for ((j = i + 1; j < ${#nic_array[@]}; j++)); do
        data_nics=("${nic_array[i]}" "${nic_array[j]}")
        echo "Data Bond deniyor: ${data_nics[*]}"
        
        create_bond "data" "$DATA_IP" "$DATA_GW" "$DATA_LACP" "${data_nics[@]}"
        
        if test_and_cleanup_bond "bond-data" "$DATA_BW" "${data_nics[@]}"; then
            echo "Başarılı Data Bond konfigürasyonu bulundu: ${data_nics[*]}"
            exit 0
        fi
    done
done

echo "Başarılı Data Bond konfigürasyonu bulunamadı."
exit 1
