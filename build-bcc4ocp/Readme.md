How to use

podman run -itd --privileged \
  -v /lib/modules:/lib/modules:ro \
  -v /sys:/sys:ro \
  -v /usr/src:/usr/src:ro \
  quay.io/openshift-psap-qe/perftools:ocp4.16.27 bash
  
  podman run --privileged --name bpf-ocp     --mount type=bind,source=/sys/kernel/debug,target=/sys/kernel/debug     -it quay.io/openshift-psap-qe/peftools:ocp4.16.27
  
oc debug --image=quay.io/openshift-psap-qe/perftools:ocp4.16.27 node/ip-xxx.xxx.xxx
  
podman run -it --rm --privileged \
--pid host \
-v ${PWD}:/out \
-v /etc/localtime:/etc/localtime:ro \
--pid host \
-v /sys/kernel/debug:/sys/kernel/debug \
-v /sys/fs/cgroup:/sys/fs/cgroup \
-v /sys/fs/bpf:/sys/fs/bpf \
--net host \
quay.io/openshift-psap-qe/perftools:ocp4.16


podman run -it --rm --privileged \
--pid host \
-v ${PWD}:/out \
-v /etc/localtime:/etc/localtime:ro \
--pid host \
-v /lib/modules:/lib/modules \
-v /sys/:/sys/ \
-v /usr/src:/usr/src \
--net host \
quay.io/openshift-psap-qe/perftools:ocp4.16.27 bash

podman run -it --rm --privileged \
--pid host \
-v ${PWD}:/out \
-v /etc/localtime:/etc/localtime:ro \
--pid host \
-v /lib/modules:/lib/modules \
-v /sys/:/sys/ \
-v /usr/src:/usr/src \
--net host \
quay.io/openshift-psap-qe/perftools:yum-bpftool bash
