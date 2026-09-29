# Scaleway File Storage avec ESXi : résultats de validation

Tests réels du 29 septembre 2026 sur un Elastic Metal ESXi 7.0.3 de test en `fr-par-2`, un File Storage de 500 Go et deux Instances Linux. Les chiffres ci-dessous sont les **médianes de trois passages** avec `fio`, un job, profondeur 1, `O_DIRECT=1`, fichier de 256 MiB. Ils décrivent cette configuration, pas un SLA.

## Performances observées

| Chemin testé | Écriture 1 MiB | Écriture aléatoire 4 KiB | Latence p99 4 KiB | Erreurs sur 3 passages |
|---|---:|---:|---:|---|
| VirtioFS direct, passerelle | 57,9 MiB/s | 455 IOPS | 3,29 ms | Aucune dans `fio` |
| Image ext4 en loopback sur VirtioFS, passerelle | 62,4 MiB/s | 449 IOPS | 3,36 ms | Aucune dans `fio` |
| VirtioFS direct, seconde VM | 57,9 MiB/s | 462 IOPS | 3,23 ms | Aucune dans `fio` |
| NFSv4.1 réexportant directement VirtioFS, seconde VM | — | — | — | `ESTALE` avant `fio`, 3/3 |
| NFSv4.1 réexportant l'image ext4, seconde VM | 47,2 MiB/s | 105 IOPS | 14,48 ms | Aucune dans `fio` |

Le chemin NFS sur image ext4 fonctionne, mais ses écritures aléatoires 4 KiB sont environ **4,4 fois plus lentes** que l'accès VirtioFS direct sur la même VM. Les lectures NFS mesurées après échauffement sont servies en partie par les caches et ne démontrent pas le débit du File Storage.

Une publication de 512 MiB de données aléatoires depuis le disque local vers File Storage a réussi avec SHA-256 identique après relecture, en 9,25 s (55,3 MiB/s sur ce passage).

## Fonctionnement et erreurs

| Chemin | `flock` entre deux VMs | Test ESXi | Verdict |
|---|---|---|---|
| VirtioFS direct | **Échec dans les deux sens** : le second hôte acquiert le verrou déjà détenu | ESXi ne monte pas VirtioFS | Convient seulement aux applications qui gèrent elles-mêmes la coordination distribuée. |
| VirtioFS → NFSv4.1 | Verrou respecté dans les deux sens | Le datastore monte, mais création d'un VMDK : **`Stale file handle`** | À écarter pour les VMDK. |
| Image VirtioFS → cible iSCSI `tgt` → VMFS6 | Non testé | LUN découvert ; création VMFS6 échoue après commande SCSI `0x89` rejetée | À écarter dans cette configuration. |
| Image ext4 loopback → NFSv4.1 | Verrou respecté dans les deux sens | Datastore monté ; 20 VMDK fins de 16 MiB créés puis supprimés sans erreur | Piste fonctionnelle, mais une interruption NFS de 6 s a bloqué une E/S cliente **63,1 s** ; pas prête pour la production. |

`fallocate` sur le File Storage a renvoyé `Operation not supported` ; l'image de 8 GiB a été créée avec `truncate`, puis montée avec `losetup --direct-io=on` (`DIO=1`). Le loopback ne garantit donc pas à lui seul la disparition des erreurs du stockage sous-jacent et impose **un seul monteur de l'image en écriture**.

**Décision actuelle :** pour des VMDK ESXi de production, garder un datastore VMware sur un stockage bloc/local/NFS prévu pour cet usage et utiliser File Storage pour les fichiers publiés ou sauvegardes validées par checksum. Pour des fichiers applicatifs partagés, l'accès VirtioFS direct avec verrou applicatif externe et travail temporaire sur disque local est le chemin le plus simple si l'application peut être adaptée. La passerelle NFS sur image ext4 reste une expérimentation pour les applications qui imposent `flock`.

La [procédure complète, les paramètres, limites et références aux JSON bruts](docs/validation-2026-09-29.md) permettent de refaire les mesures. Le [banc minimal](benchmarks/validation/README.md) remplace les anciens scripts Terraform/Ansible de ce dépôt, qui ne contenaient pas de résultats vérifiables.

Licence : MIT.
