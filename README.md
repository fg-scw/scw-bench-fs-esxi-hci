# File Storage, NFS et ESXi : résultats de validation

## Conclusion

Le NFSv4.1 direct sur VirtioFS échoue en `ESTALE` (3/3), malgré `flock` réussi entre deux hôtes. L'ext4 loopback passe un test court, mais écrit lentement en 4 KiB ; une coupure NFS de 6 s bloque une E/S 63,145 s.

Pour les applications existantes, je retiendrais une passerelle NFS sur un vrai volume bloc ext4/XFS, à valider en charge. Les VMs ESXi monteraient NFS dans leur OS invité et tous les clients utiliseraient le même service. Cette alternative n'a pas été mesurée ici et ne conserve pas File Storage comme stockage primaire. Une seule passerelle reste un point de panne ; plusieurs serveurs indépendants ne suffisent pas à assurer la haute disponibilité.

## Banc testé

```text
File Storage 500 Go
  +-- VirtioFS --> Passerelle --+-- NFS direct ---------> client Linux / ESXi
  |                           +-- image ext4 --> NFS -> client Linux / ESXi
  +-- VirtioFS --> Seconde Instance (comparaison en accès direct)

Alternative non testée : volume bloc --> ext4/XFS --> NFS --> applications
Autres essais : image --> iSCSI --> ESXi/VMFS6 (échec)
               disque local --> publication File Storage (SHA-256 OK)
```

Essais du 29 septembre 2026 : ESXi 7.0.3, deux Instances et File Storage en
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

À profondeur 1, les chiffres n'indiquent pas le maximum d'IOPS ; les lectures
en cache ne donnent pas le débit soutenu. Trois passages ne valident pas la charge concurrente.
L'écriture 4 KiB NFS/ext4 est 4,4 fois plus lente que VirtioFS direct.

## Verrous, handles et ESXi

| Chemin applicatif | `flock` entre hôtes | Handles / résultat |
|---|---|---|
| VirtioFS direct | Échec dans les deux sens | Les deux hôtes acquièrent le même verrou exclusif |
| NFSv4.1 sur VirtioFS direct | Passe dans les deux sens | Opérations de fichiers en `ESTALE`, 3/3 |
| NFSv4.1 sur image ext4 loopback | Passe dans les deux sens | Fonctionne au test court ; interruption NFS très bloquante |

ESXi : l'export direct monte mais échoue à créer un VMDK ; ext4 a passé 20 créations/suppressions de VMDK 16 MiB, sans VM démarrée ; iSCSI/VMFS6 échoue après découverte du LUN.

Un verrou externe peut coordonner les applications adaptées. Il ne répare pas
les handles, n'invalide pas les caches et n'empêche pas à lui seul un ancien
détenteur d'écrire après expiration de son verrou. Un seul hôte doit monter l'image ext4 en
écriture ; `fallocate` étant indisponible, elle a été créée avec `truncate`.

## Rapport et preuves

- [Rapport complet, procédure et limites](docs/validation-2026-09-29.md)
- [Banc `fio`](benchmarks/validation/README.md) · [script](benchmarks/validation/run.py)
- [Terraform de validation](terraform/validation/main.tf)
- [Résultats bruts JSON](benchmarks/results/)

Licence : MIT.
