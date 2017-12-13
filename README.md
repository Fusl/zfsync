# zfsync
zfsync is a simple tool for keeping one or more ZFS storage pods synced up. It does not require any other configuration than just making sure the source/master server can automatically connect to the destination/slave server using SSH key authentication.

## Important notes
* At this time it is not possible to run zfsync on a destination/slave server as this will cause corruption of the synced ZFS datastores.
* Writing data on a synced filesystem on the destination/slave server is possible but data gets overwritten on the next zfsync pass.
* This script is a work-in-progress and proof-of-concept script. I use it to synchronize thousands of zfs datasets between multiple private storage pods (around 200T) and backup servers (around 500T).
* The script is not to be used as a snap+backup solution but rather as a simplified way of keeping two storage pools in sync.

### Installing dependency packages
* FreeBSD: `pkg install bash base64 pv pigz`
* Debian/Ubuntu: To be done
* CentOS/RedHat: To be done
* openSUSE: To be done

### Defining smaller datasets to be synced
```
./zfsync.sh init src-pool/src-dataset destination dst-pool/dst-dataset [dst-pool2/dst-dataset2 [...]]
```
Note: Your source and destination pool names and dataset names do not need to match up. This command can be used multiiple times to add multiple destinations to a single dataset.

### Defining larger datasets to be synced
```
./zfsync.sh slowinit src-pool/src-dataset destination dst-pool/dst-dataset [dst-pool2/dst-dataset2 [...]]
```
Note: The slowinit command requires you to have at least double the size of the dataset to be synced available on both servers (source & destination). For example, if your dataset is 200G large, you need at least 400G of free space available on both the source and the destination server.

slowinit works by first exporting the dataset from the source server as chunked files to an auto-created filesystem on the same pool on the source server. It then continuously tries to copy all chunks from the source to the destination servers auto-created filesystem until all files are copied. Once the files are copied, the destination server re-assembles all files into a single stream and imports it to the final datastore.

This command makes sure that - whatever happens to the SSH connections - the initial sync - which, depending on the dataset size, might take hours to days to finish with the `init` command - always finishes at one point.

### Synchronize a single dataset to all destinations of this dataset
```
./zfsync.sh sync src-pool/src-dataset
```

### Synchronize all datasets to all destinations
```
./zfsync.sh sync
```
Note: This is a wrapper between a somewhat complex `zfs list` and the `sync` commands
