#!/bin/bash

# UP olan NIC'leri listele
up_nics=$(ip a | awk '/state UP/ {print $2}' | sed 's/://g' | grep -v 'lo')

# UP olan NIC'leri diziye dönüştür
IFS=$'\n' read -r -d '' -a nic_array < <(printf '%s\n' "$up_nics" && printf '\0')

# Kullanıcıdan gerekli bilgileri al
read -p "Data Bond ismi: " DATA_BOND_NAME
read -p "Data NIC bant genişliği (Gbps): " DATA_BW
read -p "Data Bond Gateway: " DATA_GW
read -p "Data Bond IP Adresi: " DATA_IP

read -p "Backup Bond ismi: " BACKUP_BOND_NAME
read -p "Backup NIC bant genişliği (Gbps): " BACKUP_BW
read -p "Backup Bond IP Adresi: " BACKUP_IP

# Bond oluşturma fonksiyonu
create_bond() {
    local bond_name=$1
    local ip=$2
    local gw=$3
    shift 3
    local nics=("$@")
    
    # Bond'u oluştur ve nics ekle
    nmcli con add type bond ifname "$bond_name" mode active-backup
    for nic in "${nics[@]}"; do
        nmcli con add type ethernet ifname "$nic" master "$bond_name"
    done
    
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
for ((i = 0; i < ${#nic_array[@]} - 1; i++)); do
    for ((j = i + 1; j < ${#nic_array[@]}; j++)); do
        data_nics=("${nic_array[i]}" "${nic_array[j]}")
        echo "Data Bond deniyor: ${data_nics[*]}"
        
        create_bond "$DATA_BOND_NAME" "$DATA_IP" "$DATA_GW" "${data_nics[@]}"
        
        if test_and_cleanup_bond "$DATA_BOND_NAME" "$(( 2 * DATA_BW ))" "${data_nics[@]}"; then
            echo "Başarılı Data Bond konfigürasyonu bulundu: ${data_nics[*]}"
            
            # Data bond slave'lerini hariç tutarak kalan NIC'leri belirle
            remaining_nics=()
            for nic in "${nic_array[@]}"; do
                if [[ ! " ${data_nics[@]} " =~ " ${nic} " ]]; then
                    remaining_nics+=("$nic")
                fi
            done
            
            # Backup Bond'u oluştur ve test et
            for ((k = 0; k < ${#remaining_nics[@]} - 1; k++)); do
                for ((l = k + 1; l < ${#remaining_nics[@]}; l++)); do
                    backup_nics=("${remaining_nics[k]}" "${remaining_nics[l]}")
                    echo "Backup Bond deniyor: ${backup_nics[*]}"
                    
                    create_bond "$BACKUP_BOND_NAME" "$BACKUP_IP" "" "${backup_nics[@]}"
                    
                    if test_and_cleanup_bond "$BACKUP_BOND_NAME" "$(( 2 * BACKUP_BW ))" "${backup_nics[@]}"; then
                        echo "Başarılı Backup Bond konfigürasyonu bulundu: ${backup_nics[*]}"
                        exit 0
                    fi
                done
            done
            
            echo "Başarılı Backup Bond konfigürasyonu bulunamadı."
            exit 1
        fi
    done
done

echo "Başarılı Data Bond konfigürasyonu bulunamadı."
exit 1
