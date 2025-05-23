This creates two keepalived instances, master on rpi1 and backup on rpi2, which in hand allows you to have a single virtual IP across both nodes via 192.168.188.200.
Also created are two HAProxy instances that loadbalance incomming traffic/requests across the cluster (rpi1, rpi2, rpi3, rpi4).
Nginx is then installed across the cluster with one instance on each node.
To deploy run 
              docker stack deploy -c docker-compose.yml ha-stack

              root@rpi1:/home/rpi/cluster/ha-swarm/bin# docker service ls
ID             NAME                         MODE         REPLICAS   IMAGE                    PORTS
l34k02mac7kq   ha-stack_haproxy-backup      replicated   1/1        haproxy:latest           
4hstqyuiefhh   ha-stack_haproxy-master      replicated   1/1        haproxy:latest           
0b8tixw34k50   ha-stack_keepalived-backup   replicated   1/1        y0mg/keepalived:latest   
s4o6woa4up4j   ha-stack_keepalived-master   replicated   1/1        y0mg/keepalived:latest   
wxja9v4m67q6   ha-stack_web                 replicated   4/4        nginx:latest    

You do need to have a docker swarm setup with at least 4 nodes in it.
