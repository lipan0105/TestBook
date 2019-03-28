#!/bin/bash

ips=$1
if [ "${ips}" = "" ]; then
    echo "[ERROR]: ips is null ,please input ip list for fitos ssl..."
    echo "param format: sh gen_ssl_ca.sh ip1,ip2,ip3"
    exit 1
fi

# get vip from ip list
vip=`echo $ips | awk -F',' {'print $1'}`
if [ "${vip}" = "" ]; then
    echo "[ERROR]: can not get vip from ip list."
    exit 1
fi

# create ca index and serial
mkdir -p /etc/pki/CA/newcerts
rm -rf /etc/pki/CA/index.txt
touch /etc/pki/CA/index.txt 
touch /etc/pki/CA/serial 
echo "01" > /etc/pki/CA/serial

# create ssl dir
ssl_dir='/opt/ssl_key'
rm -rf $ssl_dir
mkdir -p $ssl_dir
cd $ssl_dir

#copy openssl config file from template
openssl_file='openssl.cnf'
openssl_template=/home/get_ssl/$openssl_file
config_file=$ssl_dir/$openssl_file
rm -f $config_file
cp $openssl_template $config_file
if [[ "$?" != "0" ]]; then
    echo "[ERROR]: failed to copy ${config_temple} to ${config_file}"
    exit 1
fi

sed -i '/^DNS.*/d' $config_file
sed -i '/^IP.*/d' $config_file

ip_list=(`echo $ips | awk -F',' {'for(i=1;i<=NF;i++) print $i'}`)
i=1
for ip in ${ip_list[*]}
do
  echo "DNS.$i = $ip" >> $config_file
  let i++
done

i=1
for ip in ${ip_list[*]}
do
  echo "IP.$i = $ip" >> $config_file
  let i++
done

# begin to gen ssl ca files
openssl genrsa -out ca.key 1024
if [[ "$?" != "0" ]]; then
    echo "[ERROR]: failed to genrsa ca.key"
    exit 1
fi

openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj '/C=CN/ST=Shaanxi/L=Xian/O=Fiberhome/OU=FitOS/CN='$vip
if [[ "$?" != "0" ]]; then
    echo "[ERROR]: failed to gen req ca.key to ca.crt"
    exit 1
fi

openssl genrsa -out server.key 1024
if [[ "$?" != "0" ]]; then
    echo "[ERROR]: failed to gen rea server.key"
    exit 1
fi

openssl req -new -key server.key -out server.csr -subj '/C=CN/ST=Shaanxi/L=Xian/O=Fiberhome/OU=FitOS/CN='$vip -config $openssl_file
if [[ "$?" != "0" ]]; then
    echo "[ERROR]: failed to gen req server.key to server.csr"
    exit 1
fi

openssl ca -days 3650 -in server.csr -out server.crt -cert ca.crt -keyfile ca.key -extensions v3_req -extfile $openssl_file -batch
if [[ "$?" != "0" ]]; then
    echo "[ERROR]: failed to ca server.csr to server.crt"
    exit 1
fi

echo "[OK] : generate ssl ca success."
exit 0
