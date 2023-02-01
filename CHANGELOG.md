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
