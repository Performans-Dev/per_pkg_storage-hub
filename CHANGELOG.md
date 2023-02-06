## 0.0.5
* Added initial loading of files after initialization.

## 0.0.4
* Added eventListener

## 0.0.3
* Fixed an sqlite error when metadata is used.

## 0.0.2
* Added `deleteFile` method
```
bool deleted = await StorageHub.deleteFile(id: 123);
```
* Renamed `FileModel` to `FileDefinition`
* Added `getFileList` method for fetching file list from sqlite
```
List<FileDefinition> files = await StorageHub.getFileList();
```

## 0.0.1

* Initial Release
