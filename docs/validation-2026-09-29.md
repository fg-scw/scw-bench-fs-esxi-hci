# Validation du stockage — 29 septembre 2026

Ce rapport rassemble les observations du banc et leurs limites. Les liens vers `benchmarks/results/` pointent vers les preuves brutes ; aucun résultat nouveau n’a été ajouté ici.

## Contexte et mesures

Le banc a été créé par CLI Scaleway et configuré manuellement dans les machines. Les ressources de test étaient File Storage `e94fcbcb-1e47-4e12-a793-3db92f36089c`, passerelle `ce4411ed-9379-4ff6-a92e-832f127b9a6f`, seconde VM `1c998975-871d-4c6a-bc24-130158013906` et groupe de sécurité `02acb10e-80ef-4403-bdc3-c2649e4e928d`. L’ESXi existant n’a pas été redéployé. Après l’essai, le datastore NFS direct défaillant a été retiré, l’initiateur iSCSI logiciel désactivé et la cible/export iSCSI ainsi que ses fichiers de test supprimés. À la fin des essais du 29 septembre, le datastore NFS/ext4 était encore disponible ; montage et exports ont été configurés manuellement et ne redémarrent pas automatiquement avec la passerelle.

Le [Terraform de validation](../terraform/validation/main.tf) décrit une variante reproductible du File Storage et de deux Instances POP2 raccordées au réseau privé existant ; il n’a pas produit ces mesures. Il ne crée ni ESXi ni VPC, et ne configure pas l’OS, l’image ext4 ou NFS. Un `apply` avec un état vide dans le projet déjà mesuré créerait des doublons facturés : utiliser un projet de test ou importer les ressources existantes. Les variables Terraform sont décrites dans `terraform.tfvars.example`. Pour créer un nouveau banc, depuis la racine du dépôt :

```sh
cd terraform/validation
cp terraform.tfvars.example terraform.tfvars
# Renseigner project_id, private_network_id, private_network_cidr et ssh_cidr.
terraform init
terraform plan
terraform apply
terraform output
```

L’état et `terraform.tfvars` restent hors Git. Le File Storage Terraform se monte avec l’UUID de `file_storage_id` sans son préfixe régional.

Configuration mesurée : File Storage 500 Go en `fr-par-2`, monté en VirtioFS sur deux Instances ; passerelle POP2-4C-16G Ubuntu, noyau 6.8.0-139, `fio` 3.36 ; seconde VM POP2-2C-8G ; ESXi 7.0.3 build 21930508. L’image ext4 de 8 GiB résidait sur File Storage, attachée en loop avec `DIO=1`. Chaque série `fio` comporte trois passages par chemin : fichier 256 MiB, un job, profondeur 1, `ioengine=sync`, `O_DIRECT=1`, séquentiel 1 MiB sur les 256 MiB, aléatoire 4 KiB en lecture/écriture pendant 20 s par profil, puis écriture aléatoire 4 KiB avec `fdatasync` à chaque écriture. Les valeurs ci-dessous sont les médianes, sans intervalle de confiance ni charge concurrente.

| Chemin | Écriture séquentielle | Lecture séquentielle* | Écriture aléatoire 4 KiB | p99 écriture | Lecture aléatoire 4 KiB* |
|---|---:|---:|---:|---:|---:|
| Passerelle, VirtioFS | 57,9 MiB/s | 52,6 MiB/s | 455 IOPS | 3,29 ms | 772 IOPS |
| Passerelle, ext4 loopback | 62,4 MiB/s | 52,5 MiB/s | 449 IOPS | 3,36 ms | 768 IOPS |
| Seconde VM, VirtioFS direct | 57,9 MiB/s | 52,6 MiB/s | 462 IOPS | 3,23 ms | 801 IOPS |
| Seconde VM, NFS 4.1 sur ext4 loopback | 47,2 MiB/s | 356,6 MiB/s | 105 IOPS | 14,48 ms | 5 124 IOPS |

\* Le jeu de 256 MiB tient en cache : les lectures élevées sur NFS ne mesurent pas le débit soutenu du File Storage. À profondeur 1, la mesure reflète surtout la latence et non le maximum d’IOPS du service. Les écritures `fdatasync` médianes étaient d’environ 452 IOPS sur VirtioFS passerelle, 243 sur son ext4 loopback, 456 sur VirtioFS seconde VM et 104 sur NFS/ext4. Les JSON récents contiennent les latences `fdatasync`.

NFS 4.1 réexportant directement VirtioFS bloque le second hôte lors du test inter-hôtes `flock` dans les deux sens, mais le banc reçoit `ESTALE` à l’ouverture du fichier sonde, avant `fio`, dans les trois essais (3/3). Le même contrôle de verrou réussit sur NFS/ext4. Les JSON de verrous consignent les résultats entre deux hôtes, mais pas leurs chemins ni leurs montages : ils ne permettent pas d’établir que les deux utilisaient un client NFS. Le verrou ne rend donc pas le réexport direct utilisable : il ne corrige ni `ESTALE`, ni les problèmes éventuels de cache ou de fencing. VirtioFS direct laisse chaque VM acquérir le verrou détenu par l’autre. Le contrôle `fcntl.lockf` direct a aussi laissé entrer le second hôte ; cette observation n’a pas de JSON archivé.

Séries `fio` utilisées pour les médianes :

- Passerelle : [passage 1](../benchmarks/results/validation-20260929T161438Z.json), [2](../benchmarks/results/validation-20260929T161723Z.json), [3](../benchmarks/results/validation-20260929T161946Z.json).
- Seconde VM, VirtioFS/NFS direct : [passage 1](../benchmarks/results/validation-20260929T170412Z.json), [2](../benchmarks/results/validation-20260929T170523Z.json), [3](../benchmarks/results/validation-20260929T170634Z.json).
- Seconde VM, VirtioFS/NFS ext4 : [passage 1](../benchmarks/results/validation-20260929T171007Z.json), [2](../benchmarks/results/validation-20260929T171225Z.json), [3](../benchmarks/results/validation-20260929T171443Z.json).

Verrous : [VirtioFS et NFS direct](../benchmarks/results/cross-host-lock-20260929.json), [NFS/ext4](../benchmarks/results/cross-host-lock-loop-20260929.json). SHA-256, `flock` local et codes de sortie `fio` réussissent sur les chemins exécutés ; leurs détails sont dans les JSON.

## Publication, reprise et ESXi

Une publication depuis le disque local vers File Storage d’un fichier aléatoire de 512 MiB a pris 9,25 s (55,3 MiB/s) ; les SHA-256 correspondent. C’est un passage, sans garantie de débit soutenu ni de durabilité après panne : [JSON](../benchmarks/results/validation-20260929T175303Z.json). Les trois publications précédentes de 64 MiB passent aussi le SHA-256, mais leurs petits fichiers répétitifs sont sensibles au cache et leurs débits ne sont pas retenus.

Pendant un arrêt puis redémarrage de `nfs-server` de 6 s, une sonde du client NFS `hard` a mis **63,145 s** à terminer. Les 26 sondes terminées au total ont réussi et conservé leur intégrité, dont celle-ci. Le client peut donc rester bloqué bien après l’interruption du service. Le JSON de 30 s reporte cette durée dans `max_probe_s` et `slow_probes`, mais `failure_periods` est vide car aucune sonde n’a renvoyé d’erreur. Les 30 s étaient la fenêtre demandée ; une E/S bloquée peut la dépasser. Un VMDK fin a ensuite pu être créé et supprimé. Le test ne couvre ni panne de la passerelle ni coupure File Storage : [preuve](../benchmarks/results/recovery-20260929T175625Z.json).

Les essais ESXi sont secondaires à l’usage en fichiers applicatifs. iSCSI `tgt` sur image File Storage : LUN 8 GiB visible, création VMFS6 échouée, commande SCSI `0x89` rejetée (`sense 05/20/00`). NFS 4.1 réexportant VirtioFS : datastore monté et répertoire créé, puis création du VMDK fin 16 MiB échouée avec `Stale file handle`, confirmé dans `vmkernel.log` et `hostd.log`. NFS 4.1 sur ext4 loopback : création et suppression d’un VMDK fin 16 MiB réussies, puis 20 répétitions réussies (médiane 0,17 s par opération). Test court sans VM démarrée, pas une validation de datastore de production. Voir [résultats ESXi](../benchmarks/results/esxi-storage-20260929.json) et [20 répétitions](../benchmarks/results/esxi-loop-repeat-20260929.json).

## Refaire le banc

Utiliser un File Storage et des données de test seulement. Sur la passerelle et la VM cliente, installer Python 3, `fio`, `util-linux` et `e2fsprogs` ; ajouter le serveur NFS sur la passerelle et le client NFS sur la VM :

```sh
sudo apt-get update
sudo apt-get install -y python3 fio util-linux e2fsprogs
# Passerelle seulement : sudo apt-get install -y nfs-kernel-server
# VM cliente seulement : sudo apt-get install -y nfs-common
```

Préparer les points de montage et définir les valeurs selon Terraform ou votre réseau privé. Pour VirtioFS, utiliser l’UUID de `file_storage_id` (retirer le préfixe régional s’il est présent) :

```sh
sudo mkdir -p /mnt/filestorage /mnt/loop-validation /mnt/nfs-validation \
  /mnt/nfs-loop /root/validation-results
export FILE_SYSTEM_ID='UUID_DU_FILE_STORAGE'
export GATEWAY_IP='IP_PRIVEE_PASSERELLE'
export PEER_IP='IP_PRIVEE_CLIENT'
export ESXI_IP='IP_PRIVEE_ESXI'
```

Sur la passerelle, monter VirtioFS et créer une image neuve. Le contrôle empêche de reformater une image préexistante lors d’une reprise. Si elle existe, la vérifier ou choisir un autre nom ; ne pas relancer `mkfs` dessus.

```sh
sudo mount -t virtiofs "$FILE_SYSTEM_ID" /mnt/filestorage
export IMAGE=/mnt/filestorage/loop-validation.img
test ! -e "$IMAGE" || { echo "Image déjà présente : $IMAGE"; exit 1; }
sudo truncate -s 8G "$IMAGE"
sudo mkfs.ext4 -F "$IMAGE"
export LOOP_DEV=$(sudo losetup --find --show --direct-io=on "$IMAGE")
sudo mount -o noatime "$LOOP_DEV" /mnt/loop-validation
sudo losetup --list --output NAME,BACK-FILE,DIO
```

Vérifier que le `LOOP_DEV` retourné correspond à la sortie et affiche `DIO=1` ; le nom n’est pas forcément `/dev/loop0`. `truncate` crée une image sparse qui consomme l’espace au fur et à mesure. Vérifier l’espace libre. `DIO=0` a produit une première mesure aléatoire accélérée par le cache, écartée.

Sur la passerelle, limiter TCP 2049 et les exports aux adresses privées de test. Ces options permissives sont réservées aux données jetables :

```sh
sudo mkdir -p /mnt/filestorage/nfs-validation /etc/exports.d
sudo tee /etc/exports.d/fs-validation.exports >/dev/null <<EOF
/mnt/filestorage/nfs-validation $ESXI_IP(rw,sync,no_subtree_check,no_root_squash,fsid=1) $PEER_IP(rw,sync,no_subtree_check,no_root_squash,fsid=1)
/mnt/loop-validation $ESXI_IP(rw,sync,no_subtree_check,no_root_squash,fsid=2) $PEER_IP(rw,sync,no_subtree_check,no_root_squash,fsid=2)
EOF
sudo exportfs -ra
sudo systemctl enable --now nfs-kernel-server
```

Sur la seconde Instance Linux du banc, VirtioFS direct suppose que le File Storage est attaché à la VM. Pour les fichiers applicatifs, monter NFS depuis l’OS invité de chaque VM cliente ; ne pas mélanger accès direct VirtioFS et accès NFS aux mêmes données. Un datastore NFS ESXi est un autre usage. La recette ne fournit ni bascule automatique ni verrouillage HA entre passerelles indépendantes.

```sh
sudo mkdir -p /mnt/filestorage /mnt/nfs-validation /mnt/nfs-loop
sudo mount -t virtiofs "$FILE_SYSTEM_ID" /mnt/filestorage
sudo mount -t nfs4 -o vers=4.1,hard "$GATEWAY_IP:/mnt/filestorage/nfs-validation" /mnt/nfs-validation
sudo mount -t nfs4 -o vers=4.1,hard "$GATEWAY_IP:/mnt/loop-validation" /mnt/nfs-loop
```

Copier le dépôt sur chaque VM pour utiliser les commandes ci-dessous, ou copier uniquement `run.py` et adapter son chemin. Utiliser un compte pouvant écrire dans les montages et le dossier de sortie ; remplacer `/root/validation-results` si le banc n’est pas lancé comme root. Exécuter la boucle dans un script Bash ou un sous-shell. Trois passages reproduisent les séries ; conserver les JSON, y compris les `errno=116` (`ESTALE`). Le JSON est écrit même si un cas échoue, puis la commande retourne un code non nul. Cette boucle laisse les trois passages s’exécuter et conserve le statut d’échec global. Le banc crée et supprime ses répertoires temporaires ; un chemin NFS stale peut nécessiter un nettoyage depuis la passerelle.

```sh
python3 benchmarks/validation/run.py --self-test
bench_status=0
for i in 1 2 3; do
  python3 benchmarks/validation/run.py \
    --case virtiofs=/mnt/filestorage \
    --case loop-ext4=/mnt/loop-validation \
    --size 256M --runtime 20 --direct 1 --out /root/validation-results || bench_status=1
done
test "$bench_status" -eq 0
```

Sur la cliente, exécuter séparément avec `--case direct-virtiofs=/mnt/filestorage --case nfs41=/mnt/nfs-validation`, puis `--case direct-virtiofs=/mnt/filestorage --case nfs-loop-ext4=/mnt/nfs-loop`. Pour `flock` inter-hôtes, lancer un seul `--case` à la fois et configurer SSH sans mot de passe. Régler `--peer-path` sur le même répertoire partagé côté client : `/mnt/filestorage` pour VirtioFS direct, `/mnt/nfs-validation` pour cet export ou `/mnt/nfs-loop` pour l’export loopback. Pour refaire la sonde de reprise :

```sh
python3 benchmarks/validation/run.py --watch /mnt/nfs-loop \
  --watch-seconds 180 --out /root/validation-results
```

Pendant que cette commande tourne, provoquer l’interruption dans un autre terminal de la passerelle : `sudo systemctl stop nfs-kernel-server; sleep 6; sudo systemctl start nfs-kernel-server`. `hard` permet la reprise, mais peut bloquer les opérations longtemps ; ne pas remplacer cette option par `soft` pour masquer le blocage.

Pour l’essai ESXi, ajouter les exports comme datastores NFS 4.1 via le réseau privé ; un montage seul ne vaut pas validation. Le test iSCSI exposait une image distincte de 8 GiB via `tgt` (`bstype=aio`), pas l’image ext4 loopback ci-dessus. Les appels VMDK/iSCSI sont consignés dans les JSON cités, pas dans `run.py`.

## Conclusion et limites

Pour les **fichiers applicatifs RWX**, VirtioFS direct donne les mesures les plus équilibrées du banc, mais son `flock` entre hôtes n’exclut pas les accès concurrents. Le réexport NFS 4.1 offre cette exclusion dans l’essai, mais échoue sur `ESTALE` 3/3. Un verrou externe peut assurer l’exclusion applicative ; il ne répare ni `ESTALE`, ni la cohérence des caches, ni le fencing. Les clients doivent monter le même service NFS depuis leur OS invité. La passerelle unique est un point de panne ; la HA demande une validation distincte du fencing et de la reprise cohérente de l’état NFS et des verrous. Deux serveurs NFS indépendants ne constituent pas une bascule. La publication depuis disque local passe le SHA-256, sans prouver durabilité après panne ni coordination multi-écrivains.

L’ext4 loopback sur NFS passe les contrôles de verrou et le court essai VMDK, mais écrit à 105 IOPS en 4 KiB avec p99 14,48 ms ; l’arrêt NFS de 6 s a bloqué une sonde 63,145 s. Ne pas le retenir comme solution de production sur ces seules mesures. La piste standard à valider est un **vrai volume bloc monté en ext4 ou XFS sur une passerelle unique puis exporté par NFS** ; elle n’a pas été mesurée ici.

Restent à valider les charges applicatives réelles, plusieurs écrivains, la cohérence, les pannes/reboots de passerelle, `fsck` et restauration, les écritures non synchronisées, la durée sous charge et les mécanismes de haute disponibilité/sauvegarde. Aucun test VMDK n’a démarré de VM.

Références NFS : [documentation du noyau Linux sur les exports](https://docs.kernel.org/filesystems/nfs/exporting.html) et [page de manuel `nfs(5)`](https://man7.org/linux/man-pages/man5/nfs.5.html).
