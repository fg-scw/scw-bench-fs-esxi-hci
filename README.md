# Storage Benchmark : Scaleway File Storage via iSCSI (virtio-fs backend)

Benchmark des performances de stockage du **service managé Scaleway File Storage**,
exposé aux VMs via un proxy iSCSI sur instance POP2.

> **Pourquoi iSCSI et pas NFS ?**
> L'approche initiale via NFS re-export a échoué. Voir la section
> [Problématiques rencontrées](#problématiques-rencontrées) ci-dessous.

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │              Public Gateway                  │
                        │       163.172.158.12 (SSH bastion :61000)    │
                        └──────────────────┬──────────────────────────┘
                                           │
                    Private Network: storage-bench-bench-pn (172.16.100.0/24)
                                           │
            ┌──────────────────────────────┼──────────────────────────────┐
            │                              │                              │
   ┌────────┴────────┐           ┌─────────┴─────────┐          ┌─────────┴────────┐
   │  POP2 Instance   │          │  EM ESXi fr-par-2 │          │  (Proxmox HCI)   │
   │  iSCSI Proxy     │          │  172.16.100.20    │          │  hors Terraform  │
   │  172.16.100.2    │          │                   │          │                  │
   │                  │          │  ┌───────────────┐│          │  ┌────────────┐  │
   │  File Storage    │  iSCSI   │  │ VM bench      ││          │  │ VM bench   │  │
   │  500 Go          │ ◄────────┤  │ 172.16.100.22 ││          │  │ Ceph RBD   │  │
   │  (virtio-fs)     │  LUN 1   │  │               ││          │  └────────────┘  │
   │  → tgtd LUNs     │          │  └───────────────┘│          └──────────────────┘
   └──────────────────┘          └───────────────────┘
```

### Chemin I/O détaillé

```
VM (fio/pgbench/...)
  └─► iSCSI initiator (open-iscsi)
       └─► Private Network (172.16.100.0/24)
            └─► tgtd (proxy POP2, port 3260)
                 └─► fichier image LUN (/mnt/filestorage/iscsi-lun-vm.img)
                      └─► virtio-fs
                           └─► Scaleway File Storage (service managé)
```

## Problématiques rencontrées

Le déploiement initial reposait sur un **export NFSv4** depuis le proxy POP2 vers les
VMs ESXi. Cette approche a révélé des incompatibilités fondamentales :

### 1. Erreurs `ESTALE` (Stale File Handle)

Le re-export NFS d'un montage virtio-fs provoque la perte des descripteurs de fichiers.
Lors de charges I/O intensives (FIO, pgbench), les file handles NFS deviennent invalides
car **virtio-fs ne garantit pas la persistance des inodes** nécessaire au protocole NFS.

### 2. Incompatibilité virtio-fs / ESXi

Le protocole virtio-fs est un canal local hôte-invité (KVM/QEMU). Il ne peut pas être
attaché directement à une VM sur ESXi car l'hyperviseur VMware ne sait pas émuler ce
type de matériel virtuel. L'accès au File Storage nécessite donc obligatoirement un
proxy intermédiaire.

### 3. Conflits de cache et d'inodes

La gestion dynamique des inodes par le socle managé entre en conflit avec le cache du
serveur NFS sur le proxy, provoquant des corruptions de session sous charge.

### Solution retenue : iSCSI via tgtd

Le proxy POP2 crée des **fichiers images sparse** sur le File Storage (monté en
virtio-fs), puis les expose comme **LUNs iSCSI** via `tgtd`. Cette approche fonctionne
car tgtd fait des I/O blocs sur un seul fichier — pas de gestion de file handles NFS.

| Composant | Rôle |
|-----------|------|
| **Scaleway File Storage** | Stockage objet managé, monté en virtio-fs sur le proxy |
| **tgtd (proxy POP2)** | Expose les fichiers images comme LUNs iSCSI sur le PN |
| **open-iscsi (VMs)** | Initiateur iSCSI, monte les LUNs comme disques blocs |
| **ext4 / VMFS6** | Filesystem sur les LUNs (ext4 pour Linux, VMFS6 pour ESXi) |

---

## Scénarios de benchmark

| # | Scénario | Chemin I/O | Ce qu'on mesure |
|---|----------|-----------|-----------------|
| **1a** | `baseline-virtiofs` | Proxy → virtio-fs → File Storage | Performance max théorique |
| **1b** | `iscsi-loopback` | Proxy → tgtd → loopback → iSCSI → ext4 | Overhead tgtd pur |
| **2** | `esxi-vm-iscsi-direct` | VM ESXi → iSCSI → Proxy → virtio-fs → FS | Performance réelle depuis VM |
| **A** | *(futur)* Proxmox → Ceph | VM → virtio-scsi → Ceph RBD → NVMe | Référence HCI |

### Scénarios proxy (Phase 1)

Exécutés directement sur l'instance POP2. Servent de baselines :

- **baseline-virtiofs** : FIO/ioping/dd/pgbench directement sur le montage virtio-fs.
  Représente la performance maximale atteignable du File Storage.
- **iscsi-loopback** : Création d'une LUN temporaire sur le File Storage, connexion
  iSCSI en localhost. Mesure l'overhead ajouté par tgtd (conversion bloc → fichier).

### Scénarios VM (Phase 2)

Exécutés depuis les VMs de benchmark sur ESXi :

- **esxi-vm-iscsi-direct** : La VM monte directement la LUN 1 via son initiateur
  iSCSI (open-iscsi). Le chemin traverse le Private Network jusqu'au proxy.

---

## Prérequis

- Terraform >= 1.5
- Ansible >= 2.15
- `sshpass` : `brew install sshpass` ou `apt install sshpass`
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
- 1 Instance POP2 (proxy iSCSI) avec File Storage 500 Go en virtio-fs
- 1 Elastic Metal ESXi

```bash
terraform output bastion          # IP PGW + port bastion
terraform output iscsi_proxy      # IP privée du proxy
terraform output iscsi_setup      # Commandes iSCSI pour VMs et ESXi
terraform output benchmark_summary
```

### Étape 2 — Configurer le proxy iSCSI

```bash
cd ansible/
ansible-playbook playbooks/01-proxy-storage.yml
```

Ce playbook :
1. Vérifie le montage virtio-fs du File Storage
2. Installe `tgtd`
3. Crée les fichiers images LUN (sparse) sur le File Storage
4. Configure le target iSCSI avec CHAP authentication
5. Désactive le Write Cache (WCE) pour des benchmarks honnêtes
6. Applique le tuning réseau TCP

Vérification attendue : `✅ Storage Proxy configured!`

### Étape 3 — Configurer l'ESXi sur le Private Network

La configuration réseau ESXi est **manuelle** via le web UI.

1. **Récupérer le VLAN ID** : Console Scaleway → Elastic Metal → onglet Private Networks
2. **Ajouter un Port Group** : `Private Network`, VLAN ID, vSwitch0
3. **Ajouter un VMkernel NIC** : IP `172.16.100.20/24` sur le Port Group
4. **Configurer `VM Network`** : VLAN ID du Private Network

### Étape 4 — Créer la VM benchmark sur ESXi

1. **Create VM** : 4 vCPU, 8 Go RAM, 50 Go disque **local** (NVMe)
2. Network: `VM Network` (avec VLAN)
3. Installer Ubuntu 24.04, IP statique `172.16.100.22/24`

### Étape 5 — Installer les outils et connecter iSCSI

```bash
cd ansible/

# Éditer l'inventaire si nécessaire
vim inventory/hosts.yml

# Vérifier la connectivité
ansible -m ping esxi-bench-vm-direct
ansible -m ping storage-bench-nfs-proxy

# Installer outils + connecter iSCSI + formater ext4
ansible-playbook playbooks/02-benchmark-prep.yml
```

Le playbook `02-benchmark-prep.yml` :
1. Installe fio, ioping, bonnie++, pgbench, sysbench sur tous les hosts
2. Configure CHAP et les timeouts iSCSI sur les VMs
3. Connecte la LUN iSCSI, formate ext4, monte sur `/mnt/iscsi-bench`

### Étape 6 — Lancer les benchmarks

```bash
# Phase 1 : Baselines sur le proxy (virtio-fs + iSCSI loopback)
ansible-playbook playbooks/03-run-benchmarks.yml --tags baseline

# Phase 2 : Benchmarks VM (iSCSI direct depuis ESXi)
ansible-playbook playbooks/03-run-benchmarks.yml --tags vm-bench

# Collecter et agréger les résultats
ansible-playbook playbooks/04-collect-results.yml
```

---

## Configuration iSCSI

### Target (proxy POP2)

| Paramètre | Valeur |
|-----------|--------|
| Target IQN | `iqn.2026-02.fr.scaleway:filestorage.bench` |
| Portal | `172.16.100.2:3260` |
| Auth | CHAP (`bench` / `benchpass123`) |
| LUN 1 | `iscsi-lun-vm.img` (50 Go sparse) — accès direct VM |
| LUN 2 | `iscsi-lun-esxi.img` (100 Go sparse) — datastore VMFS ESXi |
| Backing type | `aio` (async I/O) |
| Write Cache | **Désactivé** (write-through pour benchmarks honnêtes) |

### Initiateur (VMs Linux)

```bash
# Configuration dans /etc/iscsi/iscsid.conf
node.session.auth.authmethod = CHAP
node.session.auth.username = bench
node.session.auth.password = benchpass123
node.session.timeo.replacement_timeout = 120
node.session.queue_depth = 64
```

---

## Accès SSH

Tout l'accès SSH passe par le **bastion de la Public Gateway** :

```bash
# Proxy iSCSI
ssh -J bastion@163.172.158.12:61000 root@storage-bench-nfs-proxy.storage-bench-bench-pn.internal

# ESXi
ssh -J bastion@163.172.158.12:61000 root@storage-bench-esxi-par2.storage-bench-bench-pn.internal

# VM Benchmark
ssh -J bastion@163.172.158.12:61000 fabien@172.16.100.22
```

Config `~/.ssh/config` recommandée :

```
Host *.storage-bench-bench-pn.internal 172.16.100.*
  ProxyJump bastion@163.172.158.12:61000
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
```

---

## Benchmarks exécutés

### FIO (7 profils)

| Profil | Block Size | Queue Depth | Jobs | Mesure |
|--------|-----------|-------------|------|--------|
| `random-read-4k` | 4K | 32 | 4 | IOPS lecture aléatoire |
| `random-write-4k` | 4K | 32 | 4 | IOPS écriture aléatoire |
| `mixed-randrw-4k` | 4K | 32 | 4 | IOPS mixte 70/30 |
| `seq-read-1m` | 1M | 8 | 4 | Débit lecture séquentielle |
| `seq-write-1m` | 1M | 8 | 4 | Débit écriture séquentielle |
| `db-workload-8k` | 8K | 16 | 4 | Simulation workload base de données |
| `latency-profile` | 4K | 1 | 1 | Latence pure (percentiles) |

Tous les profils utilisent `direct=1` (O_DIRECT) et `ioengine=libaio`.

### Autres outils

| Outil | Mesure |
|-------|--------|
| **ioping** | Latence I/O séquentielle et aléatoire (4K) |
| **dd** | Débit brut séquentiel (1 Go, blocs 1M) |
| **bonnie++** | Performances fichiers (create/read/delete) |
| **pgbench** | Performances PostgreSQL (TPS, latence) — scale 100, 10 clients |
| **sysbench** | FileIO multi-mode (seqrd/seqwr/rndrd/rndwr/rndrw) |

---

## Structure du projet

```
storage-benchmark-scaleway/
├── terraform/esxi-filestorage/
│   ├── main.tf               # Locals, tags, configuration iSCSI
│   ├── versions.tf            # Provider Scaleway >= 2.68
│   ├── variables.tf           # Variables (iSCSI, réseau, ESXi)
│   ├── network.tf             # VPC, PN, IPAM
│   ├── gateway.tf             # Public Gateway + SSH bastion
│   ├── filestorage.tf         # File Storage + POP2 proxy iSCSI (tgtd)
│   ├── esxi-servers.tf        # Elastic Metal ESXi
│   ├── inventory.tf           # Inventaire Ansible (bastion ProxyJump)
│   ├── outputs.tf             # Commandes SSH, iSCSI setup, summary
│   └── terraform.tfvars.example
│
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── hosts.yml          # Généré par TF, éditable pour VMs
│   │   └── group_vars/all.yml # Config iSCSI, bastion, paramètres bench
│   └── playbooks/
│       ├── 01-proxy-storage.yml   # Proxy : virtio-fs + tgtd + LUNs iSCSI
│       ├── 02-benchmark-prep.yml  # Outils + connexion iSCSI + formatage
│       ├── 03-run-benchmarks.yml  # FIO, ioping, dd, bonnie++, pgbench, sysbench
│       ├── 04-collect-results.yml # Collecte + rapport agrégé
│       └── site.yml               # Pipeline complet
│
└── benchmarks/
    ├── scripts/
    │   ├── run-all.sh
    │   ├── run-fio.sh
    │   ├── run-ioping.sh
    │   ├── run-dd.sh
    │   ├── run-bonnie.sh
    │   ├── run-pgbench.sh
    │   ├── run-sysbench.sh
    │   ├── run-mlperf-storage.sh
    │   └── collect-results.py
    └── results/
```

## Licence

MIT
