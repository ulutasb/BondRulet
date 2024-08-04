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
        BOND_NAME) BOND_NAME="$value" ;
        DATA_BW) DATA_BW="$value" ;;
        DATA_GW) DATA_GW="$value" ;;
        DATA_IP) DATA_IP="$value" ;;
        DATA_LACP) DATA_LACP="$value" ;;
    
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
    nmcli con show | grep -q "$bond_name" && nmcli con delete "$bond_name"

    # Bond'u oluştur ve nics ekle
    nmcli con add type bond con-name "$bond_name"  ifname "$bond_name"
    for nic in "${nics[@]}"; do
        nmcli con add type ethernet slave-type bond con-name "$bond_name-slave-$nic"  ifname "$nic" master "$bond_name"
    done

    # LACP ayarlarını yap
    if [ "$lacp" == "evet" ]; then
        nmcli con mod "$bond_name" bond.options mode=802.3ad
    fi

    # IP ve GW ayarlarını yap
    nmcli con mod "$bond_name" ipv4.addresses "$ip"
    if [ -n "$gw" ]; then
        nmcli con mod "$bond_name" ipv4.gateway "$gw"
    fi
    nmcli con mod "$bond_name" ipv4.method manual

    # Bond'u aktif et
    nmcli con up "$bond_name"
}

# Bond'u test etme ve bant genişliği tutmazsa silme fonksiyonu
test_and_cleanup_bond() {
    local bond_name=$1
    local expected_bw=$2
    shift 2
    local nics=("$@")

    # 5 saniye bekle
    sleep 7
    #ping kontrol testi yap
    local ping_status=1
    if [ -n "$DATA_GW" ]; then
       ping -c 10 "$DATA_GW" > /dev/null 2>&1
       ping_status=$?
    fi


    # Etthool ile bant genişliğini kontrol et
    local bw=$(ethtool "$bond_name" | grep "Speed" | awk '{print $2}' | sed 's/Mb\/s//')

    if [[ "$bw" == "$expected_bw" && "$ping_status" -eq 0  ]]; then
        echo "$bond_name bondu başarıyla oluşturuldu. GW pingleniyor ve bant genişliği doğru: $bw Mb/s"
        return 0
    else
        echo "Bond $bond_name başarısız, beklenen bant genişliği: ${expected_bw} Mb/s, mevcut: $bw Mb/s"

        # Bond ve slave'leri sil
        nmcli con down "$bond_name"
        nmcli con delete "$bond_name"
        for nic in "${nics[@]}"; do
            nmcli con delete $(nmcli -t -f UUID,DEVICE,NAME con | grep "$nic" | cut -d: -f1) && echo "$nic'e tanımlanmis slave siliniyor."
        done
        return 1
    fi
}

# Data Bond'u oluştur ve test et
for ((i = 0; i < ${#nic_array[@]} - 1; i++)); do
    for ((j = i + 1; j < ${#nic_array[@]}; j++)); do
        data_nics=("${nic_array[i]}" "${nic_array[j]}")
        echo "Data Bond deniyor: ${data_nics[*]}"

        create_bond "$BOND_NAME" "$DATA_IP" "$DATA_GW" "$DATA_LACP" "${data_nics[@]}"

        if test_and_cleanup_bond "$BOND_NAME" "$DATA_BW" "${data_nics[@]}"; then
            echo "Başarılı Data Bond konfigürasyonu bulundu: ${data_nics[*]}"
            exit 0
        fi
    done
done

echo "Başarılı Data Bond konfigürasyonu bulunamadı."
exit 1
