# Storage Benchmark: Ceph HCI vs Scaleway File Storage

Benchmark comparatif des performances de stockage entre un cluster Proxmox Ceph HCI
et le service managé Scaleway File Storage (via proxy NFS sur Instance POP2).

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │              Public Gateway                  │
                        │       163.172.158.12 (SSH bastion :61000)    │
                        └──────────────────┬──────────────────────────┘
                                           │
                    Private Network: storage-bench-bench-pn (172.16.100.0/24)
                    (régional fr-par, pas de route par défaut propagée)
                                           │
            ┌──────────────────────────────┼───────────────────────────────┐
            │                              │                               │
   ┌────────┴────────┐          ┌─────────┴─────────┐          ┌─────────┴────────┐
   │  POP2 Instance   │          │  EM ESXi fr-par-2  │          │  (Proxmox HCI)   │
   │  NFS Proxy       │          │  172.16.100.20      │          │  hors Terraform  │
   │  172.16.100.2    │          │                     │          │                  │
   │                  │          │  ┌───────────────┐  │          │  ┌────────────┐  │
   │  File Storage    │   NFS    │  │ VM bench      │  │          │  │ VM bench   │  │
   │  500Go virtiofs  │◄────────┤  │ 172.16.100.22 │  │          │  │ Ceph RBD   │  │
   │  → export NFS    │         │  │ fabien/fabien  │  │          │  └────────────┘  │
   └──────────────────┘          │  └───────────────┘  │          └──────────────────┘
                                 └─────────────────────┘
```

## Principe de test

Les benchmarks mesurent la performance **du point de vue des VMs** tournant sur les
hyperviseurs. C'est le cas d'usage réel.

| Scénario | Chemin I/O | Ce qu'on mesure |
|----------|-----------|-----------------|
| **A** Proxmox → Ceph | VM → virtio-scsi → Ceph RBD → NVMe | Référence HCI |
| **B** Proxmox → NFS → FS | VM → NFS mount → proxy → virtiofs → File Storage | FS via Proxmox |
| **C** ESXi → NFS → FS | VM → NFS mount → proxy → virtiofs → File Storage | FS via ESXi |

En complément, deux baselines sur le proxy POP2 :
- **baseline-virtiofs** : accès direct File Storage (perf max théorique)
- **nfs-loopback** : NFS localhost (mesure l'overhead NFS pur)

### ⚠️ Limitation virtiofs + NFS re-export

**virtiofs ne supporte pas la ré-exportation NFS stable.** Les file handles NFS
deviennent invalides (`ESTALE`) car virtiofs ne garantit pas la persistance des inodes.

**Conséquence** : impossible d'utiliser le File Storage comme datastore NFS ESXi.
Les VMs benchmark montent le NFS **directement depuis la VM** (pas via l'hyperviseur).

---

## Prérequis

- Terraform >= 1.5
- Ansible >= 2.15
- `sshpass` (pour l'auth par mot de passe des VMs benchmark) : `brew install sshpass` ou `apt install sshpass`
- Clé SSH enregistrée dans le projet Scaleway
- Compte Scaleway avec accès Elastic Metal + File Storage

---

## Déploiement pas-à-pas

### Étape 1 — Infrastructure Terraform

```bash
cd terraform/esxi-filestorage
cp terraform.tfvars.example terraform.tfvars
# Éditer : ssh_key_ids, esxi_service_password, esxi_os_id
terraform init && terraform apply
```

Terraform déploie :
- 1 VPC + 1 Private Network (`172.16.100.0/24`)
- 1 Public Gateway avec SSH bastion (port 61000)
- 1 Instance POP2 (NFS proxy) avec File Storage 500 Go en virtiofs
- 1 Elastic Metal ESXi

**Notez les outputs** :
```bash
terraform output bastion        # IP PGW + port bastion
terraform output nfs_proxy      # IP privée du proxy (auto-assignée par IPAM)
terraform output ssh_commands   # Commandes SSH via bastion
terraform output nfs_mount_info # Commandes NFS pour les VMs
```

### Étape 2 — Vérifier l'accès SSH via bastion

```bash
# Tester le bastion
ssh -J bastion@<pgw_ip>:61000 root@storage-bench-nfs-proxy.storage-bench-bench-pn.internal

# Ou avec l'IP directe
ssh -J bastion@<pgw_ip>:61000 root@172.16.100.2
```

### Étape 3 — Configurer le proxy NFS

```bash
cd ansible/
ansible-playbook playbooks/01-proxy-nfs.yml
```

Vérification attendue : `✅ NFS Proxy configured!` avec l'export 466 Go.

### Étape 4 — Configurer l'ESXi sur le Private Network

La configuration réseau ESXi est **manuelle** via le web UI.

#### 4.1 Récupérer le VLAN ID

Console Scaleway → Elastic Metal → serveur → onglet **Private Networks** → noter le **VLAN ID**

#### 4.2 Ajouter un Port Group

1. Web UI ESXi : `https://<esxi_public_ip>/ui`
2. **Networking** → **Port groups** → **Add port group**
3. Name: `Private Network`, VLAN ID: celui noté, Virtual switch: `vSwitch0`

#### 4.3 Ajouter un VMkernel NIC

1. **VMkernel NICs** → **Add VMkernel NIC**
2. Port group: `Private Network`, Static, IP: `172.16.100.20`, Mask: `255.255.255.0`
3. Services: cocher **Management**

#### 4.4 (Optionnel) Basculer sur accès full Private Network

> ⚠️ Coupe l'accès via IP publique directe. Nécessite un Static NAT sur la PGW.

1. **TCP/IP stacks** → Edit Default → IPv4 gateway: IP de la PGW
2. Ajouter Static NAT sur la PGW : port 443 → `172.16.100.20:443`
3. Reconnecter via l'IP de la PGW
4. Supprimer `vmk0` et le port group `Management Network`
5. Éditer `VM Network` → ajouter le VLAN ID

#### 4.5 Configurer le port group VM Network

Éditer `VM Network` → VLAN ID = celui du Private Network.
Les VMs pourront communiquer sur le PN (NFS proxy, PGW, etc.).

### Étape 5 — Créer la VM benchmark sur ESXi

1. **Virtual Machines** → **Create VM**
2. Storage : datastore **local** (NVMe) — pas NFS (voir limitation virtiofs)
3. CPU: 4 vCPU, RAM: 8 Go, Disk: 50 Go
4. Network: `VM Network` (avec VLAN)
5. Installer Ubuntu 24.04, configurer IP statique sur le PN (ex: `172.16.100.22/24`)

### Étape 6 — Monter le NFS depuis la VM

```bash
# Depuis la VM benchmark
apt install -y nfs-common
mkdir -p /mnt/nfs-bench

# NFSv4 (recommandé) - avec fsid=0, le chemin est "/"
mount -t nfs4 -o rw,hard,nointr,rsize=1048576,wsize=1048576 \
  <proxy_ip>:/ /mnt/nfs-bench

# Vérifier
echo "test" > /mnt/nfs-bench/test && cat /mnt/nfs-bench/test

# Persister
echo "<proxy_ip>:/ /mnt/nfs-bench nfs4 rw,hard,nointr,rsize=1048576,wsize=1048576 0 0" >> /etc/fstab
```

### Étape 7 — Éditer l'inventaire Ansible

Éditer `ansible/inventory/hosts.yml`, section `benchmark_vms` :

```yaml
    benchmark_vms:
      vars:
        ansible_ssh_extra_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
      hosts:
        esxi-bench-vm:
          ansible_host: 172.16.100.22
          ansible_user: fabien
          ansible_password: fabien
          ansible_become: true
          ansible_become_password: fabien
          bench_scenario: "esxi-vm-nfs-filestorage"
          bench_target_path: "/mnt/nfs-bench/bench-esxi"
```

> **Important** : l'indentation YAML doit être exacte.
> Chaque propriété du host est indentée de 2 espaces **sous** le nom du host.

### Étape 8 — Installer les outils et lancer les benchmarks

```bash
# Vérifier la connectivité
ansible -m ping esxi-bench-vm
ansible -m ping storage-bench-nfs-proxy

# Installer les outils sur le proxy + VMs
ansible-playbook playbooks/02-benchmark-prep.yml

# Baselines sur le proxy
ansible-playbook playbooks/03-run-benchmarks.yml --tags baseline

# Benchmarks sur les VMs
ansible-playbook playbooks/03-run-benchmarks.yml --tags vm-bench

# Collecter les résultats
ansible-playbook playbooks/04-collect-results.yml
```

---

## Accès SSH

Tout l'accès SSH passe par le **bastion de la Public Gateway** :

```bash
# Syntaxe générale
ssh -J bastion@<pgw_ip>:61000 <user>@<resource>.<pn>.internal

# Exemples concrets
ssh -J bastion@163.172.158.12:61000 root@storage-bench-nfs-proxy.storage-bench-bench-pn.internal
ssh -J bastion@163.172.158.12:61000 root@storage-bench-esxi-par2.storage-bench-bench-pn.internal
ssh -J bastion@163.172.158.12:61000 fabien@172.16.100.22

# Ansible utilise ProxyJump automatiquement (configuré dans hosts.yml)
```

Pour simplifier, ajouter dans `~/.ssh/config` :

```
Host *.storage-bench-bench-pn.internal 172.16.100.*
  ProxyJump bastion@163.172.158.12:61000
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

---

## Benchmarks exécutés

### Stockage classique
| Outil | Ce qu'il mesure |
|-------|-----------------|
| **fio** | IOPS, throughput, latence (7 profils) |
| **ioping** | Latence I/O (séquentiel + random) |
| **dd** | Throughput séquentiel brut |
| **bonnie++** | Performances fichiers (create/read/delete) |

### Workloads réalistes
| Outil | Ce qu'il mesure |
|-------|-----------------|
| **pgbench** | Performances PostgreSQL (TPS, latence) |
| **sysbench** | FileIO multi-mode (seqrd/seqwr/rndrd/rndwr) |

---

## Structure du projet

```
storage-benchmark-scaleway/
├── terraform/esxi-filestorage/
│   ├── main.tf               # locals, tags
│   ├── versions.tf            # provider Scaleway >= 2.68
│   ├── variables.tf           # toutes les variables
│   ├── network.tf             # VPC, PN (no default route), IPAM
│   ├── gateway.tf             # Public Gateway + SSH bastion
│   ├── filestorage.tf         # File Storage + POP2 proxy NFS
│   ├── esxi-servers.tf        # Elastic Metal ESXi
│   ├── inventory.tf           # Inventaire Ansible (bastion ProxyJump)
│   ├── outputs.tf             # SSH commands, NFS info, bastion
│   └── terraform.tfvars.example
│
├── ansible/
│   ├── ansible.cfg            # pas de ssh_args (laisse l'inventaire gérer)
│   ├── inventory/
│   │   ├── hosts.yml          # généré par TF, édité manuellement pour VMs
│   │   └── group_vars/all.yml
│   └── playbooks/
│       ├── 01-proxy-nfs.yml
│       ├── 02-benchmark-prep.yml
│       ├── 03-run-benchmarks.yml
│       └── 04-collect-results.yml
│
└── benchmarks/
    ├── scripts/
    └── results/
```

## Licence

MIT
