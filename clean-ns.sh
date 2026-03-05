filter=$1

if [[ $# -eq 0 ]];then
    echo please specify filter
    echo $0 test
    exit 1
fi
ns_list=`oc get ns |grep $filter | awk '{print $1}'`
for ns in $ns_list
do
   oc get ns $ns -o json| sed '/\"kubernetes\"/d' > ns-clean.json
   #jq '.metadata.finalizers = []' ns.json > ns-clean.json
   cat ns-clean.json
   echo
   echo "---------------------------"
   # 直接 replace（绕过准入）
   curl -X PUT 127.0.0.1:8001/api/v1/namespaces/$ns/finalize \
  -H "Content-Type: application/json" \
  -d @ns-clean.json
done
