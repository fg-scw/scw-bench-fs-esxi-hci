# Validation réelle du 29 septembre 2026

Ce rapport distingue les **observations** des conditions encore à valider. Les JSON de `benchmarks/results/` sont les sorties du banc ; les erreurs ESXi sont consignées dans [`esxi-storage-20260929.json`](../benchmarks/results/esxi-storage-20260929.json). Aucun test n'a touché au datastore existant de l'ESXi.

## Banc et paramètres

| Élément | Configuration |
|---|---|
| Région et File Storage | `fr-par-2`, File Storage 500 Go monté en VirtioFS sur deux Instances |
| ESXi | Elastic Metal ESXi 7.0.3 build 21930508, client NFSv4.1 et initiateur iSCSI de test |
| Passerelle | POP2-4C-16G, Ubuntu, noyau 6.8.0-139, `fio` 3.36, ext4 8 GiB sur `/dev/loop0` avec `DIO=1` |
| Seconde VM | POP2-2C-8G, accès VirtioFS direct et clients NFSv4.1 sur réseau privé |
| `fio` | 3 passages par paire sur le même hôte, 256 MiB, 1 job, profondeur 1, `ioengine=sync`, `O_DIRECT=1` ; aléatoire pendant 20 s |
| Profils | Séquentiel 1 MiB lecture/écriture ; aléatoire 4 KiB lecture/écriture ; aléatoire 4 KiB avec `fdatasync=1` par écriture |

L'ordre des cas était constant dans chaque série. Les médianes portent sur trois passages, sans intervalle de confiance ni charge VM concurrente. Les lectures d'un jeu de 256 MiB tiennent en cache : les débits de lecture NFS, notamment 356,6 MiB/s sur l'image ext4, **ne mesurent pas** le débit soutenu du File Storage. La mesure 4 KiB à profondeur 1 est une mesure de latence, pas le maximum d'IOPS du service.

Ressources créées pour le test dans le projet fourni : File Storage `e94fcbcb-1e47-4e12-a793-3db92f36089c`, passerelle `ce4411ed-9379-4ff6-a92e-832f127b9a6f`, seconde VM `1c998975-871d-4c6a-bc24-130158013906`, groupe de sécurité `02acb10e-80ef-4403-bdc3-c2649e4e928d`. L'Elastic Metal existant n'a pas été redéployé. D'après les [tarifs de stockage](https://www.scaleway.com/en/pricing/storage/) et d'[Instances](https://www.scaleway.com/en/pricing/virtual-instances/) consultés ce jour, ces trois ressources représentent environ **0,331 €/h HT**, hors IP et disques système, tant qu'elles restent provisionnées.

Après les essais, le datastore NFS direct défaillant a été retiré de l'ESXi, et l'initiateur iSCSI logiciel activé pour le test a été désactivé. La cible iSCSI, son export réseau et les fichiers de test échoués ont été retirés de la passerelle. Le datastore ESXi NFS sur image ext4 reste disponible pour inspection. Ses montages et exports ont été établis manuellement : **ils ne sont pas configurés pour redémarrer automatiquement** après un reboot de la passerelle.

## Mesures `fio` observées

| Hôte et chemin | Écriture 1 MiB | Lecture 1 MiB | Écriture 4 KiB | p99 écr. 4 KiB | Lecture 4 KiB | Erreurs |
|---|---:|---:|---:|---:|---:|---|
| Passerelle, VirtioFS direct | 57,9 MiB/s | 52,6 MiB/s | 455 IOPS | 3,29 ms | 772 IOPS | 0/3 passages |
| Passerelle, ext4 loopback `DIO=1` | 62,4 MiB/s | 52,5 MiB/s | 449 IOPS | 3,36 ms | 768 IOPS | 0/3 passages |
| Seconde VM, VirtioFS direct | 57,9 MiB/s | 52,6 MiB/s | 462 IOPS | 3,23 ms | 801 IOPS | 0/3 passages |
| Seconde VM, NFS exportant directement VirtioFS | — | — | — | — | — | `ESTALE` avant `fio`, 3/3 passages |
| Seconde VM, NFS exportant l'ext4 loopback | 47,2 MiB/s | 356,6 MiB/s* | 105 IOPS | 14,48 ms | 5 124 IOPS* | 0/3 passages |

\* Valeurs de lecture gonflées par les caches ; elles sont conservées comme observation, pas comme performance du backend.

Les cinq profils ont terminé avec un code `fio` nul sur les chemins qui ont pu être exécutés. Les tests d'intégrité SHA-256 et `flock` **entre processus d'un même hôte** ont réussi sur ces chemins. Le profil `sync-write-4k` a donné environ 452 IOPS sur la passerelle VirtioFS, 243 IOPS sur son ext4 loopback, 456 IOPS sur la seconde VM VirtioFS et 104 IOPS sur NFS/loopback. La latence p99 du `fdatasync` est archivée dans les JSON récents ; le p99 d'écriture dans le tableau est la latence d'achèvement de l'E/S mesurée par `fio`.

Les séries brutes sont :

- Passerelle VirtioFS/loopback : [`16:14:38`](../benchmarks/results/validation-20260929T161438Z.json), [`16:17:23`](../benchmarks/results/validation-20260929T161723Z.json), [`16:19:46`](../benchmarks/results/validation-20260929T161946Z.json).
- Seconde VM VirtioFS/NFS direct : [`17:04:12`](../benchmarks/results/validation-20260929T170412Z.json), [`17:05:23`](../benchmarks/results/validation-20260929T170523Z.json), [`17:06:34`](../benchmarks/results/validation-20260929T170634Z.json).
- Seconde VM VirtioFS/NFS sur ext4 : [`17:10:07`](../benchmarks/results/validation-20260929T171007Z.json), [`17:12:25`](../benchmarks/results/validation-20260929T171225Z.json), [`17:14:43`](../benchmarks/results/validation-20260929T171443Z.json).

Une exécution supplémentaire sur la passerelle a publié 512 MiB de données aléatoires depuis son disque local vers File Storage en 9,25 s (55,3 MiB/s), avec SHA-256 identique après relecture. C'est **un passage**, pas une garantie de débit soutenu ni de durabilité après panne : [`JSON brut`](../benchmarks/results/validation-20260929T175303Z.json). Les trois publications précédentes de 64 MiB ont également passé le SHA-256, mais leur débit apparent était influencé par un petit jeu de données répétitives et n'est pas utilisé ici.

## Verrous, handles et ESXi

| Vérification | Résultat |
|---|---|
| `flock` entre deux VMs accédant directement au même VirtioFS | **Échec** : chaque VM acquiert le verrou exclusif que l'autre détient, dans les deux sens. |
| `flock` entre deux clients NFSv4.1 du réexport VirtioFS | Réussi dans les deux sens, mais les opérations de fichiers suivantes échouent avec `ESTALE`. |
| `flock` entre deux clients NFSv4.1 de l'ext4 loopback | Réussi dans les deux sens. |
| ESXi, iSCSI `tgt` sur image File Storage | LUN 8 GiB visible, mais VMFS6 échoue ; commande SCSI `0x89` rejetée (`sense 05/20/00`). |
| ESXi, NFSv4.1 réexportant directement VirtioFS | Datastore monté et répertoire créé ; création d'un VMDK fin de 16 MiB échoue avec `Stale file handle`, confirmé par `vmkernel.log` et `hostd.log`. |
| ESXi, NFSv4.1 réexportant l'ext4 loopback | Datastore monté ; VMDK fin de 16 MiB créé (0,59 s) puis supprimé (0,58 s). Puis 20 créations/suppressions de VMDK fins de 16 MiB sans erreur : médiane 0,17 s pour chaque opération. Test fonctionnel court, sans VM démarrée. |

Preuves des verrous : [`VirtioFS/NFS direct`](../benchmarks/results/cross-host-lock-20260929.json) et [`NFS sur ext4`](../benchmarks/results/cross-host-lock-loop-20260929.json). Un `flock` local réussi sur VirtioFS **ne** prouve donc **pas** le verrouillage entre hôtes. Le test POSIX `fcntl.lockf` direct entre les deux VMs a également laissé entrer le second hôte pendant que le premier détenait le verrou ; il n'a pas été répété dans les JSON.

Les [20 répétitions de l'opération VMDK](../benchmarks/results/esxi-loop-repeat-20260929.json) vérifient les opérations de création/suppression, pas les E/S d'une VM en fonctionnement.

### Coupure contrôlée de la passerelle NFS

Une boucle sur la seconde VM a écrit, synchronisé, relu et supprimé un fichier de 4 KiB toutes les 250 ms sur le montage NFS/loopback. `nfs-server` a été arrêté 6 s puis redémarré, sans arrêter la VM passerelle. Les 26 sondes terminées ont conservé leur intégrité et aucune erreur système n'a été renvoyée, **mais une sonde est restée bloquée 63,145 s**. Le client NFS `hard` a donc repris, avec une indisponibilité applicative très supérieure aux 6 s d'arrêt du service. Un VMDK fin de 16 MiB a ensuite été créé et supprimé avec succès depuis l'ESXi. [Résultat brut](../benchmarks/results/recovery-20260929T175625Z.json). Cette expérience ne couvre ni panne de la VM passerelle ni coupure du File Storage.

## Procédure pour refaire les mesures

Les commandes ci-dessous doivent être lancées **sur un File Storage de test dédié**. Les chemins sont ceux du banc ; remplacer l'identifiant et les adresses par ceux de votre environnement. Ne jamais monter la même image ext4 en écriture sur deux VMs.

### 1. Préparer VirtioFS et l'image ext4 sur la passerelle

```sh
mkdir -p /mnt/filestorage /mnt/loop-validation
mount -t virtiofs "$FILE_SYSTEM_ID" /mnt/filestorage
# fallocate -l 8G /mnt/filestorage/loop-validation.img -> Operation not supported
truncate -s 8G /mnt/filestorage/loop-validation.img
mkfs.ext4 -F /mnt/filestorage/loop-validation.img
losetup --find --show --direct-io=on /mnt/filestorage/loop-validation.img
mount -o noatime /dev/loop0 /mnt/loop-validation
losetup --list --output NAME,BACK-FILE,DIO   # vérifier DIO=1
```

`truncate` crée ici une image à allocation progressive. Vérifier la capacité libre et les sauvegardes avant d'envisager un usage prolongé. `DIO=0` a produit une première mesure aléatoire artificiellement rapide à cause du cache ; cette mesure a été écartée.

### 2. Préparer les deux exportations NFS de test

Installer `nfs-kernel-server` sur la passerelle et `nfs-common` sur la seconde VM. Limiter le port TCP 2049 et les exports aux IP privées des clients. Les options suivantes sont celles du **test**, sur des données jetables :

```sh
mkdir -p /mnt/filestorage/nfs-validation /etc/exports.d
cat >/etc/exports.d/fs-validation.exports <<'EXPORTS'
/mnt/filestorage/nfs-validation ESXI_IP(rw,sync,no_subtree_check,no_root_squash,fsid=1) PEER_IP(rw,sync,no_subtree_check,no_root_squash,fsid=1)
/mnt/loop-validation ESXI_IP(rw,sync,no_subtree_check,no_root_squash,fsid=2) PEER_IP(rw,sync,no_subtree_check,no_root_squash,fsid=2)
EXPORTS
exportfs -ra
```

Sur la seconde VM :

```sh
mount -t nfs4 -o vers=4.1,hard GATEWAY_IP:/mnt/filestorage/nfs-validation /mnt/nfs-validation
mount -t nfs4 -o vers=4.1,hard GATEWAY_IP:/mnt/loop-validation /mnt/nfs-loop
```

Pour ESXi, ajouter les mêmes exports comme datastores **NFS 4.1** avec l'adresse privée de la passerelle. Le test API a appelé `CreateNasDatastore`, puis `MakeDirectory`, `CreateVirtualDisk` avec `diskType=thin`, `adapterType=lsiLogic`, `capacityKb=16384`, et enfin `DeleteVirtualDisk`. Ne pas considérer un simple montage de datastore comme une validation : l'export VirtioFS direct se monte mais échoue à la création du VMDK.

### 3. Lancer les trois séries comparables

Copier [`run.py`](../benchmarks/validation/run.py) sur chaque VM, installer `fio`, puis exécuter :

```sh
python3 run.py --self-test
for i in 1 2 3; do
  python3 run.py --case virtiofs=/mnt/filestorage \
    --case loop-ext4=/mnt/loop-validation \
    --size 256M --runtime 20 --direct 1 --out /root/validation-results
done
```

La paire ci-dessus s'exécute sur la passerelle. Sur la seconde VM, remplacer `loop-ext4=/mnt/loop-validation` par `nfs41=/mnt/nfs-validation` pour l'export direct, puis par `nfs-loop-ext4=/mnt/nfs-loop` pour l'export ext4. Conserver les JSON même quand un cas contient `error.errno=116` (`ESTALE`). Les fichiers temporaires d'un chemin NFS en erreur peuvent nécessiter un nettoyage depuis la passerelle.

### 4. Vérifier les verrous et le chemin ESXi

Sur un premier hôte, lancer `flock -x CHEMIN/lock-validation -c 'echo HELD; sleep 6'`. Pendant `HELD`, lancer sur l'autre `flock -n CHEMIN/lock-validation -c 'echo ACQUIRED'` : code 1 signifie verrou refusé, code 0 signifie verrou accordé. Après six secondes, répéter : le code doit être 0. Inverser les hôtes. Répéter sur VirtioFS direct, NFS direct et NFS sur ext4. L'exportation NFS et le client ESXi utilisent uniquement le réseau privé.

Le test iSCSI a exposé une image distincte de 8 GiB via `tgt` (`bstype=aio`) à l'initiateur ESXi. L'ESXi a découvert le LUN, mais `CreateVmfsDatastore` a échoué. Les lignes de `vmkernel.log` consignées dans le JSON montrent le rejet de `0x89`, puis l'échec VMFS6 ; ce chemin ne doit pas être annoncé fonctionnel sur la base de la seule découverte du LUN.

## Limites et décision

Un test de VMDK fin 16 MiB n'est pas une charge de VM réelle. Les essais ne couvrent pas encore : panne/reboot de passerelle pendant les écritures, `fsck` et restauration de l'image après incident, perte de données non synchronisées, longues périodes de charge, failover, ni plusieurs ESXi écrivant simultanément. La coupure NFS de 6 s a déjà induit une E/S bloquée plus d'une minute. Les commandes NFS ci-dessus n'implémentent ni haute disponibilité ni sauvegarde cohérente de l'image.

L'option la plus simple pour des **fichiers applicatifs** est VirtioFS direct avec verrou externe si l'application le permet, disque local pour les fichiers temporaires, et publication contrôlée des fichiers terminés. Pour des **VMDK ESXi de production**, ces résultats ne valident pas File Storage comme datastore primaire. L'architecture ext4 loopback → NFS est la seule passerelle ayant passé le test VMDK court, mais ses écritures 4 KiB sont beaucoup plus lentes et sa résilience reste à démontrer.
