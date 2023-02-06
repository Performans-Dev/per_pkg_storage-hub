library storage_hub;

import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/adapter.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

const String tag = 'StorageHub';

class StorageHub {
  StorageHub._();
  static final StorageHub hub = StorageHub._();

  /// returns `true` if configuration completed
  static bool isConfigured = false;

  /// Base url of the API end point of your Storage Hub
  static String apiEndpointBaseUrl = '';

  /// Part url of your upload request to obtain a session id
  static String apiEndpointPostUrl = '?uploadType=resumable&name=';

  /// Part url of your upload operation
  static String apiEndpointPutUrl = '?upload_id=';

  /// api key of your storage hub
  static String apiSecurityKey = '';

  /// the length of file parts to send in one chunk.
  static int chunkSizeInBytes = 1024 * 89;

  /// retry count to determine that operation is actually an error.
  /// when an upload task returns error, `errorCount` is increased
  /// by one and `processStartTime` updates 15 minutes from current time.
  /// The error might be temporary, so 15 minutes later it will retry
  /// the same file. if it fails again, it will increase `errorCount` and
  /// queue for another 15 minutes.
  /// After `errorTreshold` times the file will be marked as error and wont
  /// retry anymore.
  static int errorTreshold = 100;

  /// list of your files
  static List<FileDefinition> fileList = [];

  /// returns `true` if any file is uploading currently
  static bool isSyncing = false;

  /// returns `FileDefinition` of the file that is
  /// currently being uploaded.
  /// It will return null if upload operation is idle.
  static FileDefinition? syncingFile;

  /// progress of the current upload operation. min:0, max:1
  /// it will return 0 if there is no operation.
  static double progress = 0;

  /// onEvent callback
  static Function(dynamic)? _onEvent;

  /// Configuration/Initialization method
  static configure({
    required String baseUrl,
    required String apiKey,
    String? postUrl = '?uploadType=resumable&name=',
    String? putUrl = '?upload_id=',
    int? chunkSize,
    int? retryCount,
    Function(dynamic)? onEvent,
  }) async {
    apiEndpointBaseUrl = baseUrl;
    apiSecurityKey = apiKey;
    if (postUrl != null) apiEndpointPostUrl = postUrl;
    if (putUrl != null) apiEndpointPutUrl = putUrl;
    if (chunkSize != null) chunkSizeInBytes = chunkSize;
    if (retryCount != null) errorTreshold = retryCount;
    _onEvent = onEvent;
    isConfigured = true;
    fileList = await _DbProvider.db.getFilesByStatus();
  }

  /// add a file to database
  /// filePath, fileName, totalBytes are required
  /// time is optional,
  /// `DateTime.now().toIso8601String()` will be used if null
  /// metadata is a map that you may want to store any
  /// info related to your file.
  /// it will be sent to Storage Hub during upload.
  static Future<bool> addFile({
    required String filePath,
    required String fileName,
    required int totalBytes,
    Map<String, dynamic>? metadata,
    String? time,
  }) async {
    FileDefinition file = FileDefinition(
      filePath: filePath,
      fileName: fileName,
      time: time ?? DateTime.now().toIso8601String(),
      processStartTime: DateTime.now().millisecondsSinceEpoch,
      totalBytes: totalBytes,
      uploadedBytes: 0,
      status: SyncStatus.idle,
      errorCount: 0,
      metadata: metadata ?? {},
    );
    int result = await _DbProvider.db.insertFile(file: file);
    fileList = await _DbProvider.db.getFilesByStatus();
    return result > 0;
  }

  /// Deletes the file specified by id
  /// id can be obtained from `FileDefinition file.id`
  /// from your list
  static Future<bool> deleteFile({required int id}) async {
    int result = await _DbProvider.db.deleteFile(id: id);
    fileList = await _DbProvider.db.getFilesByStatus();
    return result > 0;
  }

  /// Triggers synchronozation of files that are waiting for upload
  /// The operation will perform for the first file in queue depending
  /// on status of the file.
  /// If the file did started to upload before, this time it will resume
  static void triggerSync() async {
    if (isSyncing) return;
    //
    syncingFile = await _populateFileList();

    isSyncing = syncingFile != null;

    try {
      await _startProgress();
    } catch (err) {
      log(err.toString(), name: "StorageHub");
      isSyncing = false;
    }
  }

  /// This will return a fileList
  /// Different than `StorageHub.fileList`, this will
  /// use SQLite data source instead of ram.
  static Future<List<FileDefinition>> getFileList() async {
    return await _DbProvider.db.getFilesByStatus();
  }

  static Future<FileDefinition?> _populateFileList() async {
    fileList = await _DbProvider.db.getFilesByStatus();
    if (fileList.isEmpty) return null;
    fileList.sort(
        (a, b) => a.processStartTime ?? 0.compareTo(b.processStartTime ?? 0));
    var list = fileList.where((e) => e.status == SyncStatus.idle).toList();
    return list.isNotEmpty ? list.first : null;
  }

  static Future<void> _startProgress() async {
    if (syncingFile == null) return;
    if (syncingFile!.sessionId != null && syncingFile!.sessionId!.isNotEmpty) {
      // put
      syncingFile!.status = SyncStatus.uploading;
      _updateSyncingFileInList();
      await _DbProvider.db.updateFile(file: syncingFile!);
      syncingFile = await _NetworkProvider.putFile(
        file: syncingFile!,
        onEvent: _onEvent,
      );
    } else {
      // post
      syncingFile!.status = SyncStatus.requestingUpload;
      _updateSyncingFileInList();
      await _DbProvider.db.updateFile(file: syncingFile!);
      syncingFile = await _NetworkProvider.requestUpload(file: syncingFile!);
    }
    _updateSyncingFileInList();
    switch (syncingFile!.status) {
      case SyncStatus.idle:
        // not completed
        _startProgress();
        break;
      case SyncStatus.requestingUpload:
      case SyncStatus.uploading:
        // ongoing network operation
        return;
      case SyncStatus.uploaded:
        // completed

        await _DbProvider.db.deleteFile(id: syncingFile?.id ?? 0);
        isSyncing = false;
        syncingFile = null;
        triggerSync();
        break;
      case SyncStatus.error:
        if (syncingFile!.errorCount >= StorageHub.errorTreshold) {
          // error treshold reached -> delete file
          await _DbProvider.db.deleteFile(id: syncingFile!.id!);
        } else {
          // set file to retry again
          syncingFile!.processStartTime =
              DateTime.now().millisecondsSinceEpoch + (1000 * 60 * 15);
          syncingFile!.status = SyncStatus.idle;
          await _DbProvider.db.updateFile(file: syncingFile!);
        }
        isSyncing = false;
        syncingFile = null;
        triggerSync();
        break;
    }
  }

  static void _updateSyncingFileInList() {
    if (syncingFile == null || fileList.isEmpty) return;
    int index = fileList.map((e) => e.id).toList().indexOf(syncingFile!.id!);
    if (index < 0) return;
    fileList.replaceRange(index, index + 1, [syncingFile!]);
  }
}

/// Enum for Synchronization States
/// idle: file is queued for upload
/// requestingUpload: file has a session for upload task
/// uploading: file is currently being uploading
/// uploaded: file has been uploaded
/// error: file upload task had encountered an error
enum SyncStatus {
  idle,
  requestingUpload,
  uploading,
  uploaded,
  error,
}

class FileDefinition {
  int? id;
  String? time;
  String filePath;
  String fileName;
  int totalBytes;
  int uploadedBytes;
  String? sessionId;
  SyncStatus status;
  int errorCount;
  int? processStartTime;
  Map<String, dynamic>? metadata;
  FileDefinition({
    this.id,
    this.time,
    required this.filePath,
    required this.fileName,
    required this.totalBytes,
    required this.uploadedBytes,
    this.sessionId,
    required this.status,
    required this.errorCount,
    this.processStartTime,
    this.metadata,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'time': time,
        'filePath': filePath,
        'fileName': fileName,
        'totalBytes': totalBytes,
        'uploadedBytes': uploadedBytes,
        'sessionId': sessionId,
        'syncStatus': status.index,
        'errorCount': errorCount,
        'processStartTime': processStartTime,
        'metadata': metadata != null ? json.encode(metadata) : null,
      };

  Map<String, dynamic> toRow() => {
        'time': time,
        'filePath': filePath,
        'fileName': fileName,
        'totalBytes': totalBytes,
        'uploadedBytes': uploadedBytes,
        'sessionId': sessionId,
        'syncStatus': status.index,
        'errorCount': errorCount,
        'processStartTime': processStartTime,
        'metadata': metadata != null ? json.encode(metadata) : null,
      };

  factory FileDefinition.fromMap(Map<String, dynamic> map) => FileDefinition(
        id: map['id']?.toInt(),
        time: map['time'] ?? '',
        filePath: map['filePath'] ?? '',
        fileName: map['fileName'] ?? '',
        totalBytes: map['totalBytes']?.toInt() ?? 0,
        uploadedBytes: map['uploadedBytes']?.toInt() ?? 0,
        sessionId: map['sessionId'],
        status: SyncStatus.values[map['syncStatus']],
        errorCount: map['errorCount']?.toInt() ?? 0,
        processStartTime: map['processStartTime']?.toInt(),
        metadata: map['metadata'] == null
            ? null
            : Map<String, dynamic>.from(json.decode(map['metadata'])),
      );
}

class _DbProvider {
  _DbProvider._();
  static final _DbProvider db = _DbProvider._();
  Database? _database;

  Future<Database?> get database async {
    if (_database != null) return _database;
    _database = await initDb();
    return _database;
  }

  initDb() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, _Constants.databaseName);
    return await openDatabase(
      path,
      version: _Constants.databaseVersion,
      singleInstance: true,
      onCreate: _onCreateDb,
      onUpgrade: _onUpgradeDb,
      readOnly: false,
    );
  }

  _onCreateDb(Database db, int version) async {
    await db.execute(_Constants.dropStorageTable);
    await db.execute(_Constants.createStorageTable);
  }

  _onUpgradeDb(Database db, int oldVersion, int newVersion) async {
    // TODO: Backup data
    await db.execute(_Constants.dropStorageTable);
    await db.execute(_Constants.createStorageTable);
    // TODO: Restore data
  }

  Future<int> insertFile({required FileDefinition file}) async {
    final db = await database;
    if (db == null) return -1;
    try {
      log('Updating Row: ${file.toMap().toString()}', name: 'StorageHub');
      int lastId = await db.insert(
        _Keys.tableName,
        file.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return lastId;
    } catch (err) {
      log(err.toString(), name: tag);
      return -1;
    }
  }

  Future<int> deleteFile({required int id}) async {
    final db = await database;
    if (db == null) return -1;
    try {
      int deleteCount = await db.delete(
        _Keys.tableName,
        where: "${_Keys.id} = ?",
        whereArgs: ["$id"],
      );
      return deleteCount;
    } catch (err) {
      log(err.toString(), name: tag);
      return -1;
    }
  }

  Future<int> updateFile({required FileDefinition file}) async {
    final db = await database;
    if (db == null) return -1;
    try {
      Map<String, dynamic> row = file.toRow();
      log('Updating Row: ${row.toString()}', name: 'StorageHub');
      int updateCount = await db.update(
        _Keys.tableName,
        row,
        where: "${_Keys.id} = ?",
        whereArgs: ["${file.id}"],
      );
      return updateCount;
    } catch (err) {
      log(err.toString(), name: tag);
      return -1;
    }
  }

  Future<FileDefinition?> getFileById({required int id}) async {
    final db = await database;
    if (db == null) return null;
    try {
      var result = await db.query(
        _Keys.tableName,
        columns: _Constants.columns,
        where: "${_Keys.id} = ?",
        whereArgs: ["$id"],
        orderBy: _Keys.id,
        limit: 1,
      );
      if (result.isNotEmpty) return FileDefinition.fromMap(result[0]);
    } catch (err) {
      log(err.toString(), name: tag);
    }
    return null;
  }

  Future<List<FileDefinition>> getFilesByStatus({SyncStatus? status}) async {
    List<FileDefinition> fileList = [];
    final db = await database;
    if (db == null) return fileList;
    try {
      var result = await db.query(
        _Keys.tableName,
        columns: _Constants.columns,
        where: status == null ? null : "${_Keys.syncStatus} = ?",
        whereArgs: status == null ? null : ["${status.index}"],
        orderBy: "${_Keys.id} DESC",
        limit: 1000,
      );
      if (result.isNotEmpty) {
        for (var row in result) {
          fileList.add(FileDefinition.fromMap(row));
        }
      }
    } catch (err) {
      log(err.toString(), name: tag);
    }
    return fileList;
  }
}

class _NetworkProvider {
  static Dio _prepareDio({Map<String, dynamic>? headers, String? contentType}) {
    Dio dio = Dio();
    if (headers != null) dio.options.headers.addAll(headers);
    if (contentType != null) dio.options.contentType = contentType;
    dio.options.followRedirects = false;
    // dio.options.baseUrl = StorageHub.apiEndpointBaseUrl;
    (dio.httpClientAdapter as DefaultHttpClientAdapter).onHttpClientCreate =
        (HttpClient dioClient) {
      dioClient.badCertificateCallback =
          ((X509Certificate cert, String host, int port) => true);
      return dioClient;
    };
    return dio;
  }

  static Future<FileDefinition> requestUpload(
      {required FileDefinition file}) async {
    Map<String, dynamic> request = file.metadata ?? {};
    request['time'] = file.time;
    request['fileName'] = file.fileName;

    Map<String, dynamic> headers = {
      "X-Api-Key": StorageHub.apiSecurityKey,
      "Content-Type": "application/json",
      "X-Upload-Content-Type": _Utils.getContentType(file.fileName),
      "X-Upload-Content-Length": file.totalBytes,
    };

    Dio dio = _prepareDio(headers: headers, contentType: "application/json");
    String url =
        "${StorageHub.apiEndpointBaseUrl}${StorageHub.apiEndpointPostUrl}${file.fileName}";
    try {
      Response response = await dio.post(url, data: request);
      if (response.statusCode == HttpStatus.ok ||
          response.statusCode == HttpStatus.created) {
        if (response.data != null &&
            response.data['success'] == true &&
            response.data['statusCode'] == HttpStatus.ok) {
          String sessionId = response.data['data'][0]['id'];
          file.sessionId = sessionId;
          file.status = SyncStatus.idle;
        } else {
          file.status = SyncStatus.error;
        }
      } else {
        file.status = SyncStatus.error;
      }

      await _DbProvider.db.updateFile(file: file);
    } on DioError catch (err) {
      log(err.toString(), name: 'StorageHub');
    }

    return file;
  }

  static Future<FileDefinition> putFile(
      {required FileDefinition file,
      Function(int, int)? progress,
      Function(dynamic)? onEvent}) async {
    //..
    String contentType = _Utils.getContentType(file.fileName);
    Map<String, dynamic> headers = {
      "X-Api-Key": StorageHub.apiSecurityKey,
      "Content-Type": contentType,
      "Content-Range": "bytes */*",
      "Accept-Encoding": "gzip,deflate,br",
      "Accept": "*/*",
      "Content-Length": math.min(
          StorageHub.chunkSizeInBytes, file.totalBytes - file.uploadedBytes),
    };

    Dio dio = _prepareDio(headers: headers);
    String url =
        "${StorageHub.apiEndpointBaseUrl}${StorageHub.apiEndpointPutUrl}${file.sessionId}";

    final int startByte = file.uploadedBytes;
    final int endByte =
        math.min(startByte + StorageHub.chunkSizeInBytes, file.totalBytes);
    final Stream<List<int>> chunkStream =
        File(file.filePath).openRead(startByte, endByte);

    Response? r;
    try {
      var response = await dio.put(
        url,
        data: chunkStream,
        onSendProgress: progress,
      );
      r = response;
    } on DioError catch (err) {
      r = err.response;
    }

    switch (r?.statusCode) {
      case HttpStatus.created:
      case HttpStatus.ok:
        file.uploadedBytes = file.totalBytes;
        file.status = SyncStatus.uploaded;

        break;
      case HttpStatus.requestedRangeNotSatisfiable:
        file.uploadedBytes = 0;
        file.status = SyncStatus.idle;
        file.errorCount++;
        file.sessionId = null;
        break;
      case HttpStatus.permanentRedirect:
        Map<String, List<String>>? map = r?.headers.map;
        String range = map!['range']![0];
        int uploadedBytes = int.parse(range.split('=')[1].split('-')[1]);
        file.uploadedBytes = uploadedBytes;
        file.status = SyncStatus.idle;
        break;
      case HttpStatus.notFound:
        file.status = SyncStatus.idle;
        file.sessionId = null;
        file.uploadedBytes = 0;
        break;
      default:
        file.status = SyncStatus.error;
        file.errorCount++;
        break;
    }
    await _DbProvider.db.updateFile(file: file);

    if (onEvent != null) {
      onEvent({
        'fileName': file.fileName,
        'status': file.status,
        'uploadedBytes': file.uploadedBytes,
        'totalBytes': file.totalBytes,
      });
    }
    return file;
  }
}

class _Constants {
  static const String databaseName = 'storageHubDb.sqlite';
  static const int databaseVersion = 1;
  static const String dropStorageTable =
      'DROP TABLE IF EXISTS ${_Keys.tableName}';
  static const String createStorageTable = '''
    CREATE TABLE IF NOT EXISTS ${_Keys.tableName} (
      ${_Keys.id} INTEGER PRIMARY KEY AUTOINCREMENT, 
      ${_Keys.time} TEXT, 
      ${_Keys.filePath} TEXT, 
      ${_Keys.fileName} TEXT, 
      ${_Keys.totalBytes} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.uploadedBytes} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.syncStatus} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.sessionId} TEXT, 
      ${_Keys.errorCount} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.processStartTime} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.metadata} TEXT      
    )
  ''';
  static const List<String> columns = [
    _Keys.id,
    _Keys.time,
    _Keys.filePath,
    _Keys.fileName,
    _Keys.totalBytes,
    _Keys.uploadedBytes,
    _Keys.syncStatus,
    _Keys.sessionId,
    _Keys.errorCount,
    _Keys.processStartTime,
    _Keys.metadata,
  ];
}

class _Keys {
  static const String tableName = 'storageHubFiles';
  static const String id = 'id';
  static const String time = 'time';
  static const String filePath = 'filePath';
  static const String fileName = 'fileName';
  static const String totalBytes = 'totalBytes';
  static const String uploadedBytes = 'uploadedBytes';
  static const String syncStatus = 'syncStatus';
  static const String sessionId = 'sessionId';
  static const String errorCount = 'errorCount';
  static const String processStartTime = 'processStartTime';
  static const String metadata = 'metadata';
}

class _Utils {
  static String getContentType(String fileName) {
    return "image/jpeg";
  }
}
