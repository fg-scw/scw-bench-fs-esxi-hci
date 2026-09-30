# Validation NFS sur volume bloc — 30 septembre 2026

Ce suivi présente les essais courts d’une passerelle NFSv4.1 sur un volume bloc SBS 15k, formaté ext4. Ce chemin utilise le bloc comme backend, pas File Storage. Il complète les mesures du [29 septembre](validation-2026-09-29.md). Les opérations système, exports et montages ont été configurés manuellement ; Terraform décrit maintenant le volume, mais n’a pas créé ce banc.

## Configuration et `fio`

Volume neuf de 10 Go, 15 000 IOPS, zone `fr-par-2`, attaché à la passerelle POP2-4C-16G existante. Sur la passerelle, `/dev/sdb` a été formaté ext4 et monté `noatime` sur `/mnt/block-validation`. Export `rw,sync,no_subtree_check,no_root_squash,fsid=3`. Le client POP2-2C-8G a monté cet export sur `/mnt/nfs-block` en NFS 4.1 `hard,timeo=600`; `findmnt` confirme `local_lock=none`. La passerelle a aussi monté l’export depuis `127.0.0.1` sur `/mnt/nfs-block-client` pour le contrôle inter-hôtes.

Création puis attachement Scaleway CLI utilisés :

```sh
scw block volume create name=fs-validation-nfs-block-20260930 project-id=c96fe71c-bc1b-40a1-9559-eb37baeb627e from-empty.size=10GB perf-iops=15000 tags.0=fs-validation tags.1=temporary zone=fr-par-2 -o json
scw instance server attach-volume server-id=ce4411ed-9379-4ff6-a92e-832f127b9a6f volume-id=47355227-c950-4848-a758-46b0671b3445 volume-type=sbs_volume boot=false zone=fr-par-2 -o json
```

Le périphérique stable vérifié était `/dev/disk/by-id/scsi-0SCW_sbs_volume-47355227-c950-4848-a758-46b0671b3445`, correspondant à `/dev/sdb` et au volume SBS attendu. Pour le refaire, choisir un volume neuf et contrôler `lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,SERIAL` avant le formatage ; ne lancer `mkfs.ext4` que sur le volume neuf vérifié, jamais sur un volume existant. Pour un nouveau banc, remplacer l’UUID ci-dessous par celui du volume neuf. Le contrôle refuse un périphérique déjà formaté ou monté :

```sh
(
  set -e
  block_volume_id=UUID_DU_VOLUME_NEUF
  block_device="/dev/disk/by-id/scsi-0SCW_sbs_volume-$block_volume_id"
  test "$(lsblk -dn -o SERIAL "$block_device")" = "volume-$block_volume_id"
  test -z "$(lsblk -dn -o FSTYPE "$block_device")"
  test -z "$(lsblk -dn -o MOUNTPOINTS "$block_device")"
  sudo mkfs.ext4 "$block_device"
  sudo mkdir -p /mnt/block-validation
  sudo mount -o noatime "$block_device" /mnt/block-validation
)
```

Trois passages sur le client existant : fichier 256 MiB, un job, QD1, `ioengine=sync`, `O_DIRECT=1`, séquentiel 1 MiB, profils aléatoires 4 KiB pendant 20 s. Version fio 3.36, noyau 6.8.0-139. Médianes des trois passages :

| Mesure | Médiane |
|---|---:|
| Écriture séquentielle | 113,2 MiB/s |
| Lecture séquentielle* | 366,8 MiB/s |
| Écriture aléatoire 4 KiB | 390 IOPS, p99 9,63 ms |
| Lecture aléatoire 4 KiB* | 5 374 IOPS |
| Écriture aléatoire 4 KiB avec `fdatasync` | 410 IOPS |

*La charge de 256 MiB tient en cache ; ces lectures ne mesurent pas le débit soutenu. La latence `fdatasync` rapportée par fio est de quelques microsecondes au p99 ; ce champ d’acquittement n’est pas interprété ici comme une mesure de latence de durabilité. Aucun échec fio, erreur de sonde ou `ESTALE` dans les trois passages.

Par rapport au NFS sur ext4 loopback du 29 septembre, le volume bloc donne environ 2,4× le débit d’écriture séquentielle et 3,7× les IOPS d’écriture aléatoire, avec un p99 de 9,63 ms contre 14,48 ms. Ses écritures aléatoires restent en dessous de VirtioFS direct sur la même VM (390 contre 462 IOPS), avec un p99 plus élevé (9,63 contre 3,23 ms).

## Verrous et ESXi

Sur deux montages clients NFS — peer distant et montage loopback NFS de la passerelle — les tests manuels `flock` et `fcntl` ont réussi dans les deux sens : le second hôte voit sa tentative non bloquante refusée pendant la détention, puis acquiert le verrou après libération (4/4 probes). Pour rejouer, détenir le verrou 6 s sur un hôte, tenter l’acquisition non bloquante sur l’autre pendant puis après cette détention, et inverser les rôles. Utiliser `flock -x`/`flock -n` pour `flock`, puis `fcntl.lockf(..., LOCK_EX)`/`fcntl.lockf(..., LOCK_EX | LOCK_NB)` pour POSIX. Les chemins exacts et les montages sont dans le JSON de preuve. Cette vérification ne couvre pas le fencing après panne.

Deux passages séparés ont fait modifier simultanément un fichier de compteur partagé de 4 KiB par deux workers NFS sur deux noyaux clients (peer et passerelle auto-montée). Le fichier initial contenait dix chiffres `0` suivis de 4 086 octets `X`. Une barrière `READY/GO` a lancé les workers ensemble ; chacun a répété 100 fois `flock` exclusif, lecture et validation du payload, incrément sous verrou, écriture complète de 4 KiB, `fsync`, déverrouillage, puis attente de 5 ms hors section critique. Les intervalles se sont chevauchés et les deux résultats finaux étaient 200/200 avec payload intact.

Dans chaque passage, un worker a pris environ 31 s et l’autre moins d’une seconde, mais le worker lent a changé. Le second passage a mesuré 30,112 s d’attente de `flock` sur le peer dès l’itération 0 ; son I/O maximal mesuré était 4,65 ms.

Ce délai est compatible avec le délai maximal de 30 s prévu par le [client NFSv4 Linux 6.8](https://github.com/torvalds/linux/blob/v6.8/fs/nfs/nfs4proc.c#L7058), mais les mesures ne tracent pas le mécanisme exact. L’asymétrie et l’attente au verrou se répètent sans cause profonde établie au niveau du noyau NFS, du client ou du serveur ; aucun pcap n’a été collecté.

Cela confirme l’intégrité fonctionnelle observée, pas une faible latence sous contention ni une charge concurrente soutenue. Ne pas retenir ce chemin en l’état pour des écritures RWX de production sur le même fichier avec forte contention.

Le datastore NFS a passé 20 créations et suppressions de VMDK thin de 16 MiB via l’API ESXi. Aucune VM n’a démarré depuis ce datastore. C’est un smoke test, pas une validation complète de datastore ou de production.

## Reprise après interruption

Pendant une fenêtre `--watch` de 30 s démarrée à 08:39:28 UTC, `nfs-server` a été arrêté à 08:39:37 puis redémarré à 08:39:43 ; le cycle stop/start mesuré a pris 6,241 s, avec une pause de 6 s entre les commandes. Les 42 sondes ont fini avec succès et aucune n’a renvoyé d’exception ; une sonde a pris 18,971 s et a réussi après avoir traversé la coupure. Le watcher marque interruption/récupération uniquement après une exception, donc ses indicateurs correspondants restent faux. Pour rejouer, lancer `run.py --watch /mnt/nfs-block --watch-seconds 30`, vérifier que la sonde tourne, puis attendre 8 s avant `systemctl stop nfs-server`, une pause de 6 s et `systemctl start nfs-server` sur la passerelle. Ces durées ne donnent ni RTO ni borne de reprise. L’essai loopback du 29 septembre avait une seule sonde de 63,145 s sur une autre coupure ; deux observations ne prouvent pas une réduction constante du blocage.

## Rejouer et preuves

Exporter `/mnt/block-validation` avec `rw,sync,no_subtree_check,no_root_squash,fsid=3` pour le peer `172.16.12.66`, la passerelle `127.0.0.1` et ESXi `172.16.12.5`. Les deux montages NFSv4.1 du test étaient :

```sh
# Sur le peer Linux
sudo mount -t nfs4 -o vers=4.1,hard,timeo=600 172.16.12.64:/mnt/block-validation /mnt/nfs-block
# Sur la passerelle, pour le contrôle inter-hôtes depuis ses deux montages clients
sudo mount -t nfs4 -o vers=4.1,hard,timeo=600 127.0.0.1:/mnt/block-validation /mnt/nfs-block-client
```

Créer `/mnt/nfs-block` sur le peer et `/mnt/nfs-block-client` sur la passerelle avant les montages. Suivre la préparation des paquets et exports du [protocole initial](validation-2026-09-29.md#refaire-le-banc), en remplaçant le chemin exporté par `/mnt/block-validation` et `fsid` par `3`.

Sur le peer, exécuter trois passages avec le script du dépôt :

```sh
bench_status=0
for i in 1 2 3; do
  python3 benchmarks/validation/run.py \
    --case nfs-block-ext4=/mnt/nfs-block \
    --size 256M --runtime 20 --direct 1 --out /root/validation-results || bench_status=1
done
test "$bench_status" -eq 0
```

La configuration OS/exports et les montages ne sont pas provisionnés par Terraform ; les montages NFS sont manuels et non persistants. Le module décrit le volume et son attachement, sans avoir été appliqué pour ces mesures. Le volume a été créé et attaché par CLI. Au moment de ce rapport, le volume et le datastore de test restent disponibles pour rejouer les essais ; leur démontage et nettoyage restent manuels. Les applications utilisent NFS monté depuis leur OS invité ; le datastore ESXi est un usage séparé testé ici uniquement par des opérations VMDK sans VM démarrée.

- Mesures fio : [passage 1](../benchmarks/results/validation-20260930T082949146859Z.json), [2](../benchmarks/results/validation-20260930T083053528310Z.json), [3](../benchmarks/results/validation-20260930T083157830303Z.json).
- Verrous : [preuves `flock` et `fcntl`](../benchmarks/results/cross-host-lock-block-20260930.json).
- Fichier partagé : [passage 1](../benchmarks/results/shared-file-block-20260930.json) et [répétition instrumentée](../benchmarks/results/shared-file-block-repeat-20260930.json), avec le code worker conservé dans `worker_code_template` de chaque JSON.
- ESXi : [20 répétitions VMDK](../benchmarks/results/esxi-block-repeat-20260930.json).
- Interruption NFS : [fenêtre de surveillance](../benchmarks/results/recovery-20260930T083958834928Z.json) et [chronologie de coupure](../benchmarks/results/nfs-block-cut-20260930.json).
- Hôtes, montage, volume, commit et SHA-256 du runner : [environnement](../benchmarks/results/nfs-block-environment-20260930.json).
