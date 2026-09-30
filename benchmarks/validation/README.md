# Rejouer les mesures

`run.py` compare des répertoires Linux déjà montés. Il demande Python 3 et `fio` 3.x. Il crée un sous-répertoire temporaire dans chaque chemin, y vérifie SHA-256 et `flock` entre processus locaux, puis lance cinq profils `fio`. Les erreurs, dont `ESTALE`, sont inscrites dans le JSON, et le processus retourne un code non nul si un cas échoue. Utiliser uniquement un stockage et des données de test.

Préparer d’abord les montages et destinations selon le [protocole complet](../../docs/validation-2026-09-29.md). L’image ext4 loopback de 8 GiB doit avoir été créée sur un File Storage de test et attachée avec `DIO=1`. Vérifier le périphérique retourné par `losetup --find --show` ; il peut être différent de `/dev/loop0`. Ne pas relancer `mkfs` sur une image existante. Le script refuse par défaut les chemins qui ne sont pas des points de montage ; `--allow-non-mount` lève cette protection pour un essai local volontaire.

```sh
python3 benchmarks/validation/run.py --self-test
python3 benchmarks/validation/run.py \
  --case virtiofs=/mnt/filestorage \
  --case loop-ext4=/mnt/loop-validation \
  --size 256M --runtime 20 --direct 1 --out validation-results
```

Répéter trois fois par paire ; la [boucle du protocole](../../docs/validation-2026-09-29.md#refaire-le-banc) conserve les trois JSON même lorsqu’un passage échoue.

Les profils sont : écriture et lecture séquentielles 1 MiB, lecture et écriture aléatoires 4 KiB, puis écriture aléatoire 4 KiB avec `fdatasync` après chaque écriture. Paramètres mesurés : un job, profondeur 1, `ioengine=sync`, `O_DIRECT=1`, 20 s pour les profils aléatoires. Le JSON garde IOPS, MiB/s, p50/p95/p99, latences `fdatasync` disponibles, codes de sortie et données brutes `fio`.

Pour vérifier le verrou entre deux hôtes, SSH sans mot de passe doit être configuré et le chemin de la sonde doit désigner le même répertoire partagé depuis les deux hôtes :

```sh
python3 benchmarks/validation/run.py \
  --case nfs41=/mnt/nfs-validation \
  --peer utilisateur@IP_CLIENT --peer-path /mnt/nfs-validation \
  --out validation-results
```

Ce contrôle teste `flock` à distance via SSH ; il ne prouve pas à lui seul le fonctionnement applicatif de NFS. Lancer un seul `--case` avec `--peer` à la fois et régler `--peer-path` sur le même répertoire partagé côté client : `/mnt/filestorage` pour VirtioFS direct, `/mnt/nfs-validation` pour cet export, ou `/mnt/nfs-loop` pour l’export loopback. Un code SSH/probe inattendu est une erreur, pas un verrou correctement bloqué.

Pour publier un fichier aléatoire depuis un disque local vers File Storage, le script synchronise la source et le fichier temporaire, renomme le fichier publié, puis compare les SHA-256 :

```sh
python3 benchmarks/validation/run.py \
  --publish-local /mnt/local-stage --publish-to /mnt/filestorage \
  --publish-size-mib 512 --out validation-results
```

Le fichier publié reste à destination. Le débit d’un petit fichier en cache n’est pas un débit soutenu. Pour observer une reprise, démarrer `--watch MONTAGE --watch-seconds 180` puis interrompre séparément le service NFS depuis un autre terminal. `--watch` n’arrête ni ne redémarre le service. `--watch-seconds` est la fenêtre visée, pas une borne dure : une opération bloquée peut reprendre après son expiration, comme la sonde de 63,145 s archivée dans le rapport. Les clients `hard` peuvent rester bloqués longtemps.

`--case`, `--publish-to` et `--watch` exigent des répertoires existants et montés. Préparer les montages et le dossier local de publication avant la commande. Le dossier de résultats est créé automatiquement. Le script n’installe pas les paquets, ne monte pas les systèmes de fichiers et ne configure pas les exports NFS.

Les mesures et leurs limites, dont le cas NFS direct en `ESTALE` 3/3, figurent dans le [rapport de validation](../../docs/validation-2026-09-29.md).
