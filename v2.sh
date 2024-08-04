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
        DATA_BOND_NAME) DATA_BOND_NAME="$value" ;;
        DATA_BW) DATA_BW="$value" ;;
        DATA_GW) DATA_GW="$value" ;;
        DATA_IP) DATA_IP="$value" ;;
        DATA_LACP) DATA_LACP="$value" ;;
        CREATE_BACKUP_BOND) CREATE_BACKUP_BOND="$value" ;;
        BACKUP_BOND_NAME) BACKUP_BOND_NAME="$value" ;;
        BACKUP_BW) BACKUP_BW="$value" ;;
        BACKUP_IP) BACKUP_IP="$value" ;;
        BACKUP_LACP) BACKUP_LACP="$value" ;;
        DATA_SLAVES) IFS=',' read -r -a DATA_SLAVES <<< "$value" ;;
        BACKUP_SLAVES) IFS=',' read -r -a BACKUP_SLAVES <<< "$value" ;;
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
    local bw=$(ethtool "$bond_name" | grep "Speed" | awk '{print $2}')
    
    if [[ "$bw" == "${expected_bw}Gbps" ]]; then
        echo "Bond $bond_name başarıyla oluşturuldu ve bant genişliği doğru: $bw"
        return 0
    else
        echo "Bond $bond_name başarısız, beklenen bant genişliği: ${expected_bw}Gbps, mevcut: $bw"
        
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
echo "Data Bond oluşturuluyor: $DATA_BOND_NAME"
create_bond "$DATA_BOND_NAME" "$DATA_IP" "$DATA_GW" "$DATA_LACP" "${DATA_SLAVES[@]}"

if test_and_cleanup_bond "$DATA_BOND_NAME" "$(( 2 * DATA_BW ))" "${DATA_SLAVES[@]}"; then
    echo "Başarılı Data Bond konfigürasyonu bulundu: ${DATA_SLAVES[*]}"
    
    # Backup Bond'u oluştur ve test et
    if [ "$CREATE_BACKUP_BOND" == "evet" ]; then
        echo "Backup Bond oluşturuluyor: $BACKUP_BOND_NAME"
        create_bond "$BACKUP_BOND_NAME" "$BACKUP_IP" "" "$BACKUP_LACP" "${BACKUP_SLAVES[@]}"
        
        if test_and_cleanup_bond "$BACKUP_BOND_NAME" "$(( 2 * BACKUP_BW ))" "${BACKUP_SLAVES[@]}"; then
            echo "Başarılı Backup Bond konfigürasyonu bulundu: ${BACKUP_SLAVES[*]}"
            exit 0
        else
            echo "Başarılı Backup Bond konfigürasyonu bulunamadı."
            exit 1
        fi
    else
        echo "Backup Bond oluşturulmayacak."
        exit 0
    fi
else
    echo "Başarılı Data Bond konfigürasyonu bulunamadı."
    exit 1
