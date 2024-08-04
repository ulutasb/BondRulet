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
        CREATE_BACKUP_BOND) CREATE_BACKUP_BOND="$value" ;;
        BACKUP_BW) BACKUP_BW="$value" ;;
        BACKUP_IP) BACKUP_IP="$value" ;;
        BACKUP_LACP) BACKUP_LACP="$value" ;;
        BACKUP_SLAVES) BACKUP_SLAVES=($value) ;;
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
    nmcli con add type bond ifname "$bond_name" mode active-backup
    for nic in "${nics[@]}"; do
        nmcli con add type ethernet ifname "$nic" master "$bond_name"
    done
    
    # LACP ayarlarını yap
    if [ "$lacp" == "evet" ]; then
        nmcli con mod "$bond_name" bond.mode 802.3ad
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
    sleep 5
    
    # Etthool ile bant genişliğini kontrol et
    local bw=$(ethtool "$bond_name" | grep "Speed" | awk '{print $2}' | sed 's/[^0-9]//g')
    
    if [[ "$bw" -eq "$expected_bw" ]]; then
        echo "Bond $bond_name başarıyla oluşturuldu ve bant genişliği doğru: $bw Mb/s"
        return 0
    else
        echo "Bond $bond_name başarısız, beklenen bant genişliği: ${expected_bw} Mb/s, mevcut: $bw Mb/s"
        
        # Sadece bond ve slave'leri sil
        nmcli con down "$bond_name"
        nmcli con delete "$bond_name"
        for nic in "${nics[@]}"; do
            nmcli con delete $(nmcli -t -f UUID,DEVICE con | grep "$nic" | cut -d: -f1)
        done
        return 1
    fi
}

# Data Bond'u oluştur ve test et
bond_name="data"
echo "Data Bond oluşturuluyor: $bond_name"

# Bond'u oluştur ve NIC'leri ekle
create_bond "$bond_name" "$DATA_IP" "$DATA_GW" "$DATA_LACP" "${nic_array[@]}"

# Data Bond'u test et ve bant genişliğini kontrol et
if test_and_cleanup_bond "$bond_name" "$DATA_BW" "${nic_array[@]}"; then
    echo "Başarılı Data Bond konfigürasyonu bulundu."
    
    # Backup Bond'u oluştur ve test et
    if [ "$CREATE_BACKUP_BOND" == "evet" ]; then
        backup_bond_name="backup-bond"
        echo "Backup Bond oluşturuluyor: $backup_bond_name"
        
        for ((k = 0; k < ${#nic_array[@]} - 1; k++)); do
            for ((l = k + 1; l < ${#nic_array[@]}; l++)); do
                backup_nics=("${nic_array[k]}" "${nic_array[l]}")
                echo "Backup Bond deniyor: ${backup_nics[*]}"
                
                create_bond "$backup_bond_name" "$BACKUP_IP" "" "$BACKUP_LACP" "${backup_nics[@]}"
                
                if test_and_cleanup_bond "$backup_bond_name" "$BACKUP_BW" "${backup_nics[@]}"; then
                    echo "Başarılı Backup Bond konfigürasyonu bulundu: ${backup_nics[*]}"
                    exit 0
                fi
            done
        done
        
        echo "Başarılı Backup Bond konfigürasyonu bulunamadı."
        exit 1
    else
        echo "Backup Bond oluşturulmayacak."
        exit 0
    fi
else
    echo "Başarılı Data Bond konfigürasyonu bulunamadı."
    exit 1
fi
