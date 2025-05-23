This create two keepalived instance, master on rpi1 and backup on rpi2, that allows you to have a single virtual IP across both 192.168.188.200.
Also created are two HAProxy instances that loadbalance incomming traffic across the cluster (rpi1, rpi2, rpi3, rpi4).
Nginx is then installed across the cluser with one instance on each node.
To deploy run 
              docker stack deploy -c docker-compose.yml ha-stack
