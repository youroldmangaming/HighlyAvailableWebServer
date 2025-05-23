# Highly Available & Scalable Web Service Architecture

This document details a robust, highly available, and scalable web service architecture. It leverages **Keepalived** for virtual IP management, **HAProxy** for load balancing, **Nginx** as the web server, and **NFS** for centralized content, all orchestrated within a **Docker Swarm** environment.

---

## Architecture Overview

Our architecture distributes services across at least four Raspberry Pi nodes (rpi1, rpi2, rpi3, rpi4) within a Docker Swarm. Here's how the key components work together:

* **Keepalived (rpi1, rpi2):** We're using Keepalived to create a **highly available virtual IP (VIP)** at `192.168.188.200`. This ensures continuous access to our load balancers. `rpi1` acts as the master, with `rpi2` as the backup.
* **HAProxy (rpi1, rpi2):** Two HAProxy instances are set up as a highly available pair. They load balance all incoming traffic and requests across our Nginx web servers on `rpi1`, `rpi2`, `rpi3`, and `rpi4`.
* **Nginx (rpi1, rpi2, rpi3, rpi4):** An Nginx web server runs on each node in the cluster, serving our web content.
* **NFS (Centralized):** All Nginx installations connect to a central **NFS share** for content distribution. This means all web servers serve the exact same content and updates are a breeze.

---

## Technical Breakdown

### Keepalived for VIP High Availability

Keepalived is configured on `rpi1` (master) and `rpi2` (backup) to manage the virtual IP address `192.168.188.200`. If `rpi1` goes down, Keepalived automatically switches the VIP to `rpi2`, ensuring uninterrupted access to your HAProxy instances.

### HAProxy for Load Balancing

We have two HAProxy instances, one on `rpi1` and another on `rpi2`. These instances are the primary recipients of any traffic hitting our Keepalived VIP. HAProxy intelligently distributes incoming requests across the four Nginx instances (`rpi1`, `rpi2`, `rpi3`, `rpi4`), optimizing resource use and response times.

### Nginx for Web Serving

Every node in our Docker Swarm hosts an Nginx instance. Nginx is a powerful, high-performance web server that can handle many concurrent connections. This distributed setup makes our web serving layer scalable and resilient to individual node failures.

### NFS for Centralized Content

To keep content consistent and simplify management across all Nginx instances, we use an **NFS share**. Each Nginx container is set up to mount this share, giving all web servers access to the same centralized content repository. This eliminates the need to deploy content to each node separately and streamlines any content updates.

---

## Deployment

This entire architecture is deployed and managed with Docker Swarm.

1.  **Docker Swarm Setup:** You'll need a Docker Swarm cluster initialized with at least four manager or worker nodes.
2.  **Deployment Command:** From the directory containing your `docker-compose.yml` file, run:

    ```bash
    docker stack deploy -c docker-compose.yml ha-stack
    ```

This command will deploy all the defined services (Keepalived, HAProxy, Nginx) as a Docker Swarm stack named `ha-stack`, orchestrating their deployment and management across your cluster.
