
# Bond'u test etme, bant genişliği ve gateway kontrolü yapma fonksiyonu
test_and_cleanup_bond() {
    local bond_name=$1
    local expected_bw=$2
    shift 2
    local nics=("$@")
    
    # 5 saniye bekle
    sleep 5
    
    # Etthool ile bant genişliğini kontrol et
    local bw=$(ethtool "$bond_name" | grep "Speed" | awk '{print $2}' | sed 's/Mb\/s//g')
    
    # Ping testi yap
    local ping_status=1
    if [ -n "$DATA_GW" ]; then
        ping -c 4 "$DATA_GW" > /dev/null 2>&1
        ping_status=$?
    fi
    
    if [[ "$ping_status" -eq 0 && "$bw" == "$expected_bw" ]]; then
        echo "Gateway erişildi ve bant genişliği beklenildiği gibi: $bw Mb/s"
        return 0
    else
        echo "Bond $bond_name başarısız."
        if [ "$ping_status" -ne 0 ]; then
            echo "  - Gateway ($DATA_GW) erişilemiyor."
        fi
        if [[ "$bw" != "$expected_bw" ]]; then
            echo "  - Beklenen bant genişliği: ${expected_bw} Mb/s, mevcut: $bw Mb/s"
        fi
        
        # Bond ve slave'leri sil
        nmcli con down "$bond_name"
        nmcli con delete "$bond_name"
        for nic in "${nics[@]}"; do
            nmcli con delete $(nmcli -t -f UUID,DEVICE con | grep "$nic" | cut -d: -f1)
        done
        return 1
    fi
}
