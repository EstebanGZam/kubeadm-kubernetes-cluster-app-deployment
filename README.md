# Laboratorio: Instalación de un Clúster de Kubernetes con Kubeadm y Despliegue de una Aplicación

## Tabla de Contenidos
1. [Introducción](/images/#introducción)
2. [Arquitectura de la Solución](/images/#arquitectura-de-la-solución)
3. [Preparación del Entorno](/images/#preparación-del-entorno)
4. [Instalación y Configuración del Clúster](/images/#instalación-y-configuración-del-clúster)
5. [Despliegue de la Aplicación](/images/#despliegue-de-la-aplicación)
6. [Dificultades Encontradas y Soluciones](/images/#dificultades-encontradas-y-soluciones)
7. [Verificación y Pruebas](/images/#verificación-y-pruebas)
8. [Conclusiones](/images/#conclusiones)
9. [Anexos](/images/#anexos)

## Introducción

El presente informe documenta la implementación de un clúster de Kubernetes utilizando kubeadm sobre una distribución Ubuntu 24.04, así como el despliegue de una aplicación web containerizada. El proyecto se desarrolló siguiendo los lineamientos establecidos en el laboratorio de Infraestructura 3, con el objetivo de demostrar competencias en la administración de contenedores y orquestación de servicios.

La solución implementada automatiza completamente el proceso de instalación, configuración y despliegue mediante scripts de aprovisionamiento, garantizando la reproducibilidad y escalabilidad del entorno de desarrollo.

## Arquitectura de la Solución

### Componentes del Sistema

La implementación se basó en una arquitectura de clúster distribuido compuesta por:

- **Nodo Master (k8s-master)**: 192.168.56.10
  - 2 GB RAM, 2 CPUs
  - Funciones: API Server, etcd, Scheduler, Controller Manager
- **Nodos Worker**: 
  - k8s-worker1: 192.168.56.11 (1.5 GB RAM, 1 CPU)
  - k8s-worker2: 192.168.56.12 (1.5 GB RAM, 1 CPU)
- **Aplicación**: Web Flask containerizada expuesta mediante NodePort

> ![Cluster Architecture](/images/k8s_cluster_architecture.svg)

### Red de Contenedores

Se implementó Flannel como CNI (Container Network Interface) con las siguientes especificaciones:
- Red de pods: `10.244.0.0/16`
- Protocolo: VXLAN sobre interfaz `eth1`
- Configuración optimizada para VirtualBox

## Preparación del Entorno

### Estructura del Proyecto

```
├── Vagrantfile                    # Configuración de máquinas virtuales
├── master_script.sh              # Script maestro de automatización
├── .env.example                  # Plantilla de configuración
├── provisioning/
│   ├── common.sh                 # Configuración común de nodos
│   ├── master.sh                 # Configuración específica del master
│   └── worker.sh                 # Configuración específica de workers
├── K8S_files/                    # Manifiestos de Kubernetes
├── scripts/                      # Scripts de despliegue
├── app.py                        # Aplicación Flask
└── Dockerfile                    # Imagen de contenedor
```

### Configuración Inicial

Antes de ejecutar el laboratorio, se configuró el archivo [`.env`](.env.example) con las credenciales necesarias:

```bash
# Copy this file and rename it to .env, then edit the values

# ===== DOCKER HUB CONFIGURATION =====
DOCKER_USERNAME=tu_usuario_dockerhub
DOCKER_PASSWORD=tu_password_dockerhub  
DOCKER_EMAIL=tu_email@ejemplo.com

# ===== APPLICATION CONFIGURATION =====
APP_NAME=webapp
APP_VERSION=v1
APP_REPOSITORY_URL=https://github.com/mariocr73/K8S-apps.git

# ===== DATABASE CONFIGURATION (for secrets) =====
DB_USERNAME=admin
DB_PASSWORD=password123

# ===== CLUSTER CONFIGURATION =====
MASTER_IP=192.168.56.10
WORKER1_IP=192.168.56.11  
WORKER2_IP=192.168.56.12
SERVICE_NODE_PORT=30001

# ===== ADVANCED CONFIGURATION =====
# Pod wait timeout (seconds)
POD_TIMEOUT=300
# Application namespace (optional, default is 'default')
APP_NAMESPACE=default
```

## Instalación y Configuración del Clúster

### Ejecución del Script Maestro

El proceso de instalación se automatizó completamente mediante el script `master_script.sh`, el cual orquesta los siguientes pasos:

```bash
./master_script.sh
```

> ![Master Script Result](/images/master_script_result.png)

### Configuración Común de Nodos (`common.sh`)

El script `common.sh` se ejecuta en todos los nodos y realiza la instalación y configuración de todos los componentes base necesarios para el funcionamiento del clúster Kubernetes. Esta configuración es fundamental y debe aplicarse de manera idéntica en todos los nodos para garantizar la consistencia del entorno.

#### Actualización del Sistema Base
```bash
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
```

**Justificación**: Se actualiza el sistema para asegurar que todos los paquetes estén en sus versiones más recientes y securizadas, estableciendo un punto de partida común para todos los nodos.

#### Deshabilitación Completa del Swap
```bash
# Deshabilitación permanente del swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
rm -f /swap.img
systemctl stop systemd-swap 2>/dev/null || true
systemctl disable systemd-swap 2>/dev/null || true
```

**Justificación**: Kubernetes requiere obligatoriamente que el swap esté deshabilitado para funcionar correctamente. El kubelet falla al iniciar si detecta swap activo, ya que puede interferir con la gestión de recursos y el aislamiento de contenedores. Se implementa una deshabilitación exhaustiva que incluye:
- Desactivación inmediata (`swapoff -a`)
- Eliminación de entradas en fstab para persistencia
- Eliminación física de archivos de swap
- Deshabilitación de servicios systemd relacionados

> ![Swap Disabled On Master Node](/images/swap_disabled_on_master_node.png)

#### Configuración de Módulos del Kernel
```bash
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
```

**Justificación**: 
- **overlay**: Necesario para el sistema de archivos de contenedores, permite la superposición de capas de imagen
- **br_netfilter**: Esencial para el filtrado de paquetes en bridges de red, requerido para que iptables funcione correctamente con el tráfico de red de Kubernetes

#### Parámetros de Red del Sistema (sysctl)
```bash
cat <<EOF | tee /etc/sysctl.d/k8s.conf
# Requisitos core de Kubernetes
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1

# Optimizaciones para VirtualBox
net.ipv4.conf.all.forwarding        = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
net.ipv4.conf.eth0.rp_filter        = 0
net.ipv4.conf.eth1.rp_filter        = 0

# Optimizaciones de connection tracking
net.netfilter.nf_conntrack_max       = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 86400

# Límites de memoria y descriptores de archivo
fs.inotify.max_user_instances        = 8192
fs.inotify.max_user_watches          = 1048576
fs.file-max                          = 2097152
EOF
```

**Justificación**: 
- **Bridge netfilter**: Permite a iptables procesar tráfico de red bridgeado, fundamental para kube-proxy
- **IP forwarding**: Habilita el reenvío de paquetes entre interfaces, necesario para la comunicación entre pods
- **RP filter deshabilitado**: En VirtualBox, el reverse path filtering puede bloquear tráfico legítimo entre nodos
- **Connection tracking**: Aumenta los límites para manejar múltiples conexiones simultáneas
- **File limits**: Incrementa los límites para el monitoreo de archivos (inotify) usado por kubelet

#### Configuración Exhaustiva del Firewall
```bash
# Instalación y configuración de UFW
apt-get install -y ufw
ufw --force reset
ufw --force enable

# Acceso esencial
ufw allow ssh
ufw allow from 10.0.2.0/24         # Red NAT de VirtualBox
ufw allow from 192.168.56.0/24     # Red host-only de VirtualBox

# Redes de Kubernetes
ufw allow from 10.244.0.0/16       # Red de pods (Flannel)
ufw allow from 10.96.0.0/12        # Red de servicios

# Puertos del plano de control
ufw allow 6443/tcp                  # API server
ufw allow 2379:2380/tcp             # etcd server client API
ufw allow 10250/tcp                 # Kubelet API
ufw allow 10251/tcp                 # kube-scheduler
ufw allow 10252/tcp                 # kube-controller-manager
ufw allow 10256/tcp                 # kube-proxy health check

# Puertos de Flannel
ufw allow 8472/udp                  # Flannel VXLAN
ufw allow 8285/udp                  # Flannel host-gw
ufw allow 51820/udp                 # Flannel wireguard

# Rango de NodePort
ufw allow 30000:32767/tcp           # Servicios NodePort
ufw allow 30000:32767/udp           # Servicios NodePort UDP

# Permitir todo el tráfico en la interfaz privada
ufw allow in on eth1 to any
ufw allow out on eth1 to any
```

**Justificación**: Kubernetes requiere comunicación entre múltiples puertos y protocolos. Se configura UFW de manera permisiva pero controlada para:
- Mantener acceso SSH para administración
- Permitir comunicación en redes privadas de VirtualBox
- Abrir puertos específicos de componentes de Kubernetes
- Habilitar comunicación de Flannel (VXLAN sobre UDP)
- Permitir el rango completo de NodePorts para servicios

#### Instalación de Dependencias del Sistema
```bash
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    vim \
    git \
    wget \
    net-tools \
    htop \
    iptables \
    socat \
    conntrack \
    ipset
```

**Justificación de cada paquete**:
- **apt-transport-https**: Permite descargar paquetes desde repositorios HTTPS
- **ca-certificates**: Certificados de autoridades certificadoras para conexiones seguras
- **curl, wget**: Herramientas de descarga para scripts y archivos
- **gnupg**: Manejo de claves GPG para verificación de repositorios
- **git**: Control de versiones para clonación de repositorios
- **vim**: Editor de texto avanzado para configuraciones
- **net-tools**: Herramientas de red (ifconfig, netstat) para diagnóstico
- **htop**: Monitor de procesos mejorado para troubleshooting
- **iptables**: Gestión de reglas de firewall, usado por kube-proxy
- **socat**: Relay de sockets, usado por kubectl port-forward
- **conntrack**: Herramientas de connection tracking para diagnóstico de red
- **ipset**: Gestión eficiente de conjuntos de IPs para iptables

#### Instalación y Configuración de Containerd
```bash
# Instalación de versión específica
apt-get install -y containerd.io=1.6.*
apt-mark hold containerd.io

# Configuración para Kubernetes
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# Habilitación de SystemdCgroup
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Actualización de imagen sandbox
sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.9"|g' /etc/containerd/config.toml

# Activación del servicio
systemctl restart containerd
systemctl enable containerd
```

**Justificación**: 
- **Containerd**: Runtime de contenedores recomendado por Kubernetes, más liviano que Docker
- **Versión específica 1.6**: Garantiza compatibilidad y evita actualizaciones no deseadas
- **SystemdCgroup**: Mejora la integración con systemd para gestión de recursos
- **Imagen sandbox actualizada**: Asegura compatibilidad con la versión de Kubernetes instalada

> ![Container status](/images/containerd_status.png)
#### Configuración del Repositorio Kubernetes
```bash
# Limpieza de configuraciones previas
rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -f /etc/apt/sources.list.d/kubernetes.list

# Agregado del repositorio oficial
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
```

**Justificación**: Se utiliza el repositorio oficial de Kubernetes para garantizar autenticidad y obtener versiones estables de las herramientas.

#### Instalación de Herramientas Kubernetes
```bash
# Instalación de versión específica
KUBE_VERSION="1.28.2-1.1"
apt-get install -y \
    kubelet=$KUBE_VERSION \
    kubeadm=$KUBE_VERSION \
    kubectl=$KUBE_VERSION

# Prevención de actualizaciones automáticas
apt-mark hold kubelet kubeadm kubectl
```

**Justificación**:
- **kubelet**: Agente que ejecuta en cada nodo, gestiona pods y contenedores
- **kubeadm**: Herramienta de bootstrapping para crear clústeres
- **kubectl**: Cliente de línea de comandos para interactuar con el API server
- **Versión específica**: Garantiza compatibilidad entre todos los componentes
- **Hold de paquetes**: Evita actualizaciones automáticas que podrían romper el clúster

#### Configuración del Entorno kubectl
```bash
# Autocompletado y aliases para el usuario vagrant
echo 'source <(kubectl completion bash)' >> /home/vagrant/.bashrc
echo 'alias k=kubectl' >> /home/vagrant/.bashrc
echo 'complete -o default -F __start_kubectl k' >> /home/vagrant/.bashrc
```

**Justificación**: Mejora la experiencia de usuario proporcionando autocompletado de comandos y aliases para mayor productividad en la administración del clúster.

#### Configuración de Systemd para Kubelet
```bash
mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

systemctl daemon-reload
```

**Justificación**: Esta configuración permite que kubeadm gestione dinámicamente la configuración del kubelet, incluyendo parámetros específicos del nodo y configuraciones de bootstrap.

### Configuración del Nodo Master (`master.sh`)

#### Inicialización del Clúster

```bash
kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address=$MASTER_IP \
    --control-plane-endpoint=$MASTER_IP \
    --upload-certs \
    --ignore-preflight-errors=NumCPU
```

> ![Kube Init Result](/images/kube_init_result.png)

#### Configuración de kubectl
```bash
mkdir -p /home/vagrant/.kube
cp -f /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown vagrant:vagrant /home/vagrant/.kube/config
```

#### Instalación de Flannel Optimizada

Una de las principales dificultades enfrentadas fue la configuración de la red de contenedores. Se desarrolló una configuración personalizada de Flannel específicamente optimizada para VirtualBox:

```yaml
# Configuración crítica en el DaemonSet de Flannel
containers:
- name: kube-flannel
  image: docker.io/flannel/flannel:v0.24.2
  command:
  - /opt/bin/flanneld
  args:
  - --ip-masq
  - --kube-subnet-mgr
  - --iface=eth1          # Interfaz específica para VirtualBox
  - --iface-regex=eth1
```

> ![Flannel Pods Running](/images/flannel_pods_running.png)

### Configuración de Nodos Worker (`worker.sh`)

#### Verificación de Conectividad
Antes de unirse al clúster, cada worker verifica la conectividad con el master:

```bash
# Verificación de conectividad con el API server
if ! timeout 10 bash -c "</dev/tcp/$MASTER_IP/6443" 2>/dev/null; then
    echo "❌ FATAL: Cannot connect to API server port 6443 on master"
    exit 1
fi
```

#### Ejecución del Join Command
```bash
# Ejecución del comando de unión con reintentos
for attempt in {1..10}; do
    if timeout 300 bash /vagrant/join-command.sh; then
        JOIN_SUCCESS=true
        break
    fi
done
```

> ![All Nodes In Cluster](/images/all_nodes_in_cluster.png)

## Despliegue de la Aplicación

### Construcción de la Imagen Docker

#### Aplicación Flask
La aplicación desarrollada es un servidor web simple en Flask:

```python
from flask import Flask
app = Flask(__name__)

@app.route('/')
def hello_world():
    return '¡Hola Mundo desde Kubernetes!'

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0')
```

#### Dockerfile
```dockerfile
FROM python:3.9-slim

WORKDIR /app
COPY . /app

RUN pip install Flask

CMD ["python", "app.py"]
```

> ![Docker Build](/images/docker_build.png)

> **Nota:** El build y el push de la aplicación se realizaron desde la máquina host. Si se intentaba hacerlo desde algún nodo (ya fuera el master o un worker), surgían problemas relacionados con la versión de *containerd* y la que incluye la instalación de Docker. Para evitar riesgos que pudieran afectar el clúster, se prefirió hacerlo directamente desde la máquina host.

### Creación de Secrets

Se implementó la gestión segura de credenciales mediante Kubernetes Secrets:

```bash
# Secret para Docker Hub
kubectl create secret docker-registry regcred \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username="$DOCKER_USERNAME" \
    --docker-password="$DOCKER_PASSWORD" \
    --docker-email="$DOCKER_EMAIL"

# Secret para base de datos
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: db-secrets
type: Opaque
data:
  db_username: $(echo -n "$DB_USERNAME" | base64 -w 0)
  db_userpassword: $(echo -n "$DB_PASSWORD" | base64 -w 0)
EOF
```

> ![Secrets Config](/images/secrets_config.png)

### Manifiestos de Kubernetes

#### Deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hola-mundo
  template:
    metadata:
      labels:
        app: hola-mundo
    spec:
      containers:
      - name: app-container
        image: <nombre_de_usuario_en_docker_hub>/<nombre_del_repositorio>:<tag>
        ports:
        - containerPort: 5000
      imagePullSecrets:
      - name: regcred
```

#### Service
```yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp-service
spec:
  selector:
    app: hola-mundo
  ports:
    - protocol: TCP
      port: 80
      targetPort: 5000
      nodePort: 30001
  type: NodePort
```

> ![Verification of Manifests](/images/verification_of_manifests.png)

## Dificultades Encontradas y Soluciones

### 1. Configuración de Red en VirtualBox

**Problema**: La configuración estándar de Flannel no funcionaba correctamente en el entorno VirtualBox, causando problemas de conectividad entre pods.

**Solución**: Se desarrolló una configuración personalizada de Flannel especificando la interfaz de red `eth1` (red host-only de VirtualBox) mediante los parámetros:
```bash
--iface=eth1
--iface-regex=eth1
```

### 2. Gestión del Swap

**Problema**: Kubernetes requiere que el swap esté completamente deshabilitado, pero las configuraciones estándar no siempre son efectivas.

**Solución**: Se implementó una deshabilitación exhaustiva:
- Desactivación inmediata con `swapoff -a`
- Comentado de entradas en `/etc/fstab`
- Eliminación física del archivo de swap
- Verificación con comprobaciones de estado

### 3. Configuración del Firewall

**Problema**: Las reglas de firewall predeterminadas bloqueaban la comunicación entre componentes del clúster.

**Solución**: Se desarrolló una configuración específica de UFW que permite:
- Tráfico en redes privadas de VirtualBox
- Puertos específicos de Kubernetes
- Comunicación de Flannel VXLAN
- Rango completo de NodePorts

### 4. Sincronización de Nodos Worker

**Problema**: Los nodos worker intentaban unirse antes de que el master estuviera completamente inicializado.

**Solución**: Se implementó un sistema de verificación con:
- Comprobaciones de conectividad de red
- Verificación del estado del API server
- Reintentos con backoff exponencial
- Timeouts configurables

> ![Worker Joined to Cluster](/images/worker_joined_to_cluster.png)

## Verificación y Pruebas

### Estado del Clúster

> ![Cluster Verification](/images/verification.png)

### Aplicación Desplegada

> ![Pods Running](/images/pods_running.png)

### Pruebas de Conectividad

El script maestro incluye verificaciones automáticas de conectividad:

```bash
# Test de conectividad a la aplicación
for IP in "$MASTER_IP" "$WORKER1_IP" "$WORKER2_IP"; do
    if curl -s --connect-timeout 10 "http://$IP:$ACTUAL_NODE_PORT" | grep -q "Hola"; then
        print_success "Application responds at http://$IP:$ACTUAL_NODE_PORT"
        TEST_SUCCESS=true
        break
    fi
done
```

> ![App Operation](/images/app_operation.png)

> ![Curl Working](/images/curl_working.png)

### Escalado de la Aplicación

Se realizaron pruebas de escalado para verificar la funcionalidad del clúster:

```bash
kubectl scale deployment webapp-deployment --replicas=5
```

> ![Successful Scaling](/images/successful_scaling.png)

## Conclusiones

### Logros Alcanzados

1. **Implementación Exitosa**: Se logró la instalación completa de un clúster Kubernetes funcional con kubeadm sobre Ubuntu 24.04.

2. **Automatización Completa**: Se desarrolló un sistema de scripts que automatiza todo el proceso, desde la creación de VMs hasta el despliegue de aplicaciones.

3. **Optimización para VirtualBox**: Se resolvieron las dificultades específicas del entorno virtualizado mediante configuraciones personalizadas.

4. **Despliegue de Aplicación**: Se implementó exitosamente una aplicación web containerizada con exposición mediante NodePort.

5. **Gestión de Secrets**: Se implementó la gestión segura de credenciales utilizando las mejores prácticas de Kubernetes.

### Aprendizajes Técnicos

- **Configuración de Red**: La importancia de la configuración correcta de CNI en entornos virtualizados.
- **Gestión de Firewall**: La necesidad de configuraciones específicas de firewall para Kubernetes.
- **Automatización**: El valor de los scripts de aprovisionamiento para entornos reproducibles.
- **Troubleshooting**: Técnicas de diagnóstico para problemas de conectividad en clústeres.

### Valor Académico

Este laboratorio demuestra competencias en:
- Administración de sistemas Linux
- Containerización con Docker
- Orquestación con Kubernetes
- Automatización de infraestructura
- Resolución de problemas técnicos complejos

## Anexos

### Anexo A: Comandos de Verificación

```bash
# Verificar estado del clúster
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods --all-namespaces

# Verificar aplicación
kubectl get deployments
kubectl get services
kubectl logs -l app=hola-mundo

# Verificar red
kubectl get pods -n kube-flannel
ip route show | grep 10.244
```

### Anexo B: URLs de Acceso

- Master: http://192.168.56.10:30001
- Worker1: http://192.168.56.11:30001  
- Worker2: http://192.168.56.12:30001

### Anexo C: Estructura de Archivos Críticos

- **Vagrantfile**: Configuración de VMs con especificaciones de hardware y red
- **master_script.sh**: Orquestador principal del laboratorio
- **provisioning/**: Scripts de configuración automatizada de nodos
- **scripts/**: Herramientas de gestión de imágenes y despliegue

---

> **Nota**: Para desmontar todo, basta con ejecutar:
> ```
> vagrant destroy
> ```
> ¡Y listo! 🙂
