# File Storage, NFS et ESXi : résultats de validation

## Conclusion

NFS 4.1 sur un volume SBS 15k/ext4 fonctionne dans les essais courts : aucune erreur `ESTALE`, verrous inter-hôtes respectés et mises à jour partagées conservées. Ses écritures 4 KiB sont 3,7 fois plus rapides que le NFS sur image loopback.

Sous contention, une acquisition de `flock` a toutefois attendu **30,1 s** ; le délai s’est reproduit. Une coupure NFS de 6 s a aussi bloqué une sonde **19 s**. Je ne retiendrais donc pas cette configuration en l’état pour des applications exigeant une faible latence sur les mêmes fichiers. Ce chemin utilise Block Storage, pas File Storage. Pour les VMs ESXi, le partage applicatif se monte dans l’OS invité ; seuls des tests de datastore sans VM démarrée ont été faits ici.

## Banc testé

```text
File Storage 500 Go
  +-- VirtioFS --> Passerelle --+-- NFS direct ---------> client Linux / ESXi
  |                           +-- image ext4 --> NFS -> client Linux / ESXi
  +-- VirtioFS --> Seconde Instance (comparaison en accès direct)

Test 30 sept. : volume bloc SBS 15k --> ext4 --> NFS 4.1 --> client Linux
               datastore ESXi : smoke test NFS séparé, 20 cycles création/suppression VMDK sans VM démarrée
Autres essais : image --> iSCSI --> ESXi/VMFS6 (échec)
               disque local --> publication File Storage (SHA-256 OK)
```

Essais des 29 et 30 septembre 2026 : ESXi 7.0.3, deux Instances et File Storage en
`fr-par-2`. Les Instances et File Storage ont été déployés via CLI puis configurés manuellement ; l'ESXi existait déjà. Le [Terraform](terraform/validation/main.tf) décrit le banc, sans avoir été appliqué pour ces mesures.

## Performances `fio`

Médianes de trois passages, fichier 256 MiB, un job, profondeur 1,
`O_DIRECT=1`. Écritures aléatoires 4 KiB ; p99 de leur latence d'achèvement.

| Chemin | Écriture 1 MiB | Écriture aléatoire 4 KiB | p99 4 KiB | Erreurs |
|---|---:|---:|---:|---|
| VirtioFS direct, passerelle | 57,9 MiB/s | 455 IOPS | 3,29 ms | 0/3 |
| ext4 loopback, passerelle | 62,4 MiB/s | 449 IOPS | 3,36 ms | 0/3 |
| VirtioFS direct, seconde VM | 57,9 MiB/s | 462 IOPS | 3,23 ms | 0/3 |
| NFS sur VirtioFS direct, seconde VM | — | — | — | `ESTALE` avant `fio`, 3/3 |
| NFS sur ext4 loopback, seconde VM | 47,2 MiB/s | 105 IOPS | 14,48 ms | 0/3 |
| NFS sur SBS 15k ext4, seconde VM | 113,2 MiB/s | 390 IOPS | 9,63 ms | 0/3 |

À profondeur 1, les chiffres n'indiquent pas le maximum d'IOPS ; les lectures
en cache ne donnent pas le débit soutenu. Trois passages ne valident pas la charge concurrente.
Le volume bloc donne 2,4× le débit séquentiel d’écriture et 3,7× les IOPS aléatoires de l’ext4 loopback, mais son p99 reste supérieur au VirtioFS direct (9,63 ms contre 3,23 ms).

## Verrous, fichiers partagés et ESXi

| Chemin / vérification | Verrous ou conditions | Résultat |
|---|---|---|
| VirtioFS direct | Échec dans les deux sens | Les deux hôtes acquièrent le même verrou exclusif |
| NFSv4.1 sur VirtioFS direct | Passe dans les deux sens | Opérations de fichiers en `ESTALE`, 3/3 |
| NFSv4.1 sur image ext4 loopback | Passe dans les deux sens | Fonctionne au test court ; interruption NFS très bloquante |
| NFSv4.1 sur SBS 15k ext4 | `flock` et `fcntl` passent dans les deux sens | 20 créations/suppressions de VMDK thin 16 MiB ; aucune VM démarrée |
| Deux clients NFS sur SBS, même fichier | 100 mises à jour par client, deux passages | 200/200 conservées à chaque passage ; attente `flock` **30,1 s** au passage instrumenté |
| Coupure NFS sur SBS | Arrêt de 6 s, client `hard` | Une sonde bloquée **18,971 s**, puis succès sans erreur |

ESXi : l’export direct monte mais échoue à créer un VMDK ; ext4 loopback et volume bloc ont chacun passé 20 créations/suppressions de VMDK 16 MiB, sans VM démarrée ; iSCSI/VMFS6 échoue après découverte du LUN.

Le [rapport du 30 septembre](docs/validation-2026-09-30.md) décrit la contention et la coupure. Ces essais courts ne valident ni la haute disponibilité ni un délai maximal de reprise.

Un verrou externe peut coordonner les applications adaptées. Il ne répare pas
les handles, n'invalide pas les caches et n'empêche pas à lui seul un ancien
détenteur d'écrire après expiration de son verrou. Pour l’ancien test ext4 loopback,
un seul hôte devait monter l’image en écriture ; `fallocate` étant indisponible,
elle avait été créée avec `truncate`.

## Rapport et preuves

- [Suivi volume bloc SBS 15k, résultats, protocole et limites](docs/validation-2026-09-30.md)
- [Rapport complet du 29 septembre, procédure et limites](docs/validation-2026-09-29.md)
- [Banc `fio`](benchmarks/validation/README.md) · [script](benchmarks/validation/run.py)
- [Terraform de validation](terraform/validation/main.tf)
- [Résultats bruts JSON](benchmarks/results/)

Licence : MIT.
