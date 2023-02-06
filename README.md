# storage_hub

This Flutter package can store files on device and chunk upload to your storage when triggered.

With Flutter:

```
 $ flutter pub add storage_hub
```

This will add a line like this to your package's pubspec.yaml (and run a implicit flutter pub get):

```
dependencies:
    storage_hub: ^0.0.5
```

Alternatively, your editor might support flutter pub get. Check the docs for your editor to learn more.

Import it
Now in your Dart code, you can use:

```
import 'package:storage_hub/storage_hub.dart;
```

## How to Use

Init Package in your main function

```
void main() {
    if (!StorageHub.isConfigured) {
        StorageHub.configure(
            apiKey: 'YOUR_API_KEY',
            chunkSize: 128 * 1024,
            retryCount: 10,
            baseUrl: 'BASE_URL_OF_YOUR_HUB',
            portUrl: 'PART_URL_OF_YOUR_UPLOAD_REQUEST_TO_OBTAIN_SESSION',
            putUrl: 'PART_URL_FOR_UPLOAD_WITH_SESSION',
        );
    }

    runApp(const MyApp());
}
```

Add your files whenever required.

```
bool result = await StorageHub.addFile(
        filePath: '/data/0/a_folder/another_folder/',
        fileName: 'my_picture.jpg',
        totalBytes: 25234, //TOTAL BYTE COUNT OF YOUR FILE
        metadata: {
            "someCustomKey": "someCustomValue",
            "anotherKey": "anotherValue",
        },
    );
```

Get a list of your files whenever required

```
List<FileDefinition> myFiles = StorageHub.fileList; // returns file list stored on ram
```

or
Query your file list

```
List<FileDefinition> myFiles = await StorageHub.getFileList(); // returns file list from database
```

You can delete a file if required

```
bool deleted = await StorageHub.deleteFile(id: 123); // you can obtain id from FileDefinition in your list
```

And finally you can trigger sender

```
StorageHub.triggerSync();
```

This will run a process that starts/resumes upload task for your file list one by one.

StorageHub will remove uploded file from list.

StorageHub will update FileDefinition with syncStatus and uploaded bytes.

StorageHub will queue any failed operation for retry.

## Definitions
`StorageHub.isSyncing` is a `bool` that returns true when there is an upload operation.

`StorageHub.syncingFile` is `FileDefinition?` that returns currently uploading file if exists.

`StorageHub.progress` is a `double` that returns the upload progress of the operation between 0 and 1.

`StorageHub.fileList` is a `List<FileDefinition>` that are added by you.

## Methods
`StorageHub.addFile()` is an async method for adding a file\
accepts: `String filePath`, `String fileName`, `int totalBytes`, `Map<String,dynamic>? metadata` and `String? time`\
returns: `bool` true if add operation is success.

`StorageHub.deleteFile()` is an async method for deleting a file\
accepts: `String id`\
returns: `bool` true if delete operation is success.

`StorageHub.getFileList()` is an async method for list of your files\
returns: `List<FileDefinition>`

`StorageHub.triggerSync()` is a void method for triggering upload operations.

## ENUMS
`SyncStatus` is an enum for the status of the file

## MODELS
`FileDefinition` is the model of the file.

