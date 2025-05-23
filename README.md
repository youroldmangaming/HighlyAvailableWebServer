This creates two keepalived instances, master on rpi1 and backup on rpi2, which in hand allows you to have a single virtual IP across both nodes via 192.168.188.200.

Also created are two HAProxy instances that loadbalance incomming traffic/requests across the cluster (rpi1, rpi2, rpi3, rpi4).

Nginx is then installed across the cluster with one instance on each node.

Each Nginx install connects to a NFS share for centralised content distribution.

To deploy run 
              docker stack deploy -c docker-compose.yml ha-stack

You do need to have a docker swarm setup with at least 4 nodes in it.
