cat << EOF > disable-https.script
#!/bin/bash
iptables -A OUTPUT -p tcp --dport 80 -j DROP
iptables -A OUTPUT -p tcp --dport 443 -j DROP
EOF

var_local=$(cat ./disable-https.script | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(''.join(sys.stdin.readlines())))"  )

cat <<EOF > 45-worker-disable-https-service.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: "worker-nohttps"
  name: 45-worker-disable-https-service
spec:
  config:
    ignition:
      version: 2.2.0
    storage:
      files:
      - contents:
          source: data:text/plain,${var_local}
          verification: {}
        filesystem: root
        mode: 0755
        path: /etc/rc.d/disable-https.local
    systemd:
      units:
      - name: disable-https.service
        enabled: true
        contents: |
          [Unit]
          Description=/etc/rc.d/disable-https.local Compatibility
          ConditionFileIsExecutable=/etc/rc.d/disable-https.local
          After=network.target

          [Service]
          Type=oneshot
          User=root
          Group=root
          ExecStart=/bin/bash -c /etc/rc.d/disable-https.local

          [Install]
          WantedBy=multi-user.target

EOF
oc apply -f 45-worker-disable-https-service.yaml -n openshift-cluster-node-tuning-operator
