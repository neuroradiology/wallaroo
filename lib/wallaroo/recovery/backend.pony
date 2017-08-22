use "buffered"
use "collections"
use "files"
use "format"
use "wallaroo/core"
use "wallaroo/fail"
use "wallaroo/messages"
use "sendence/bytes"

// (is_watermark, origin_id, uid, frac_ids, statechange_id, seq_id, payload)
type LogEntry is (Bool, U128, U128, FractionalMessageId, U64, U64,
  Array[ByteSeq] iso)

// used to hold a receovered log entry that might need to be replayed on
// recovery
// (origin_id, uid, frac_ids, statechange_id, seq_id, payload)
type ReplayEntry is (U128, U128, FractionalMessageId, U64, U64, ByteSeq val)

//////////////////////////////////
// Helpers for RotatingFileBackend
//////////////////////////////////
primitive HexOffset
  fun apply(offset: U64): String iso^ =>
    Format.int[U64](where x=offset, fmt=FormatHexBare, width=16,
      fill=48)

  fun u64(hex: String): U64 ? =>
    hex.u64(16)

primitive FilterLogFiles
  fun apply(base_name: String, suffix: String = ".evlog",
    entries: Array[String] iso): Array[String]
  =>
    let es: Array[String] val = consume entries
    recover
      let filtered: Array[String] ref = Array[String]
      for e in es.values() do
        try
          if (e.find(base_name) == 0) and
             (e.rfind(suffix) == (e.size() - suffix.size()).isize()) then
            filtered.push(e)
          end
        end
      end
      Sort[Array[String], String](filtered)
      filtered
    end

primitive LastLogFilePath
  fun apply(base_name: String, suffix: String = ".evlog", base_dir: FilePath):
    FilePath ?
  =>
    let dir = Directory(base_dir)
    let filtered = FilterLogFiles(base_name, suffix, dir.entries())
    let last_string = filtered(filtered.size()-1)
    FilePath(base_dir, last_string)

/////////////////////////////////
// BACKENDS
/////////////////////////////////

trait Backend
  fun ref sync() ?
  fun ref datasync() ?
  fun ref start_log_replay()
  fun ref write(): USize ?
  fun ref encode_entry(entry: LogEntry)

class DummyBackend is Backend
  new create() => None
  fun ref sync() => None
  fun ref datasync() => None
  fun ref start_log_replay() => None
  fun ref write(): USize => 0
  fun ref encode_entry(entry: LogEntry) => None

class FileBackend is Backend
  //a record looks like this:
  // - is_watermark boolean
  // - origin id
  // - seq id (low watermark record ends here)
  // - uid
  // - size of fractional id list
  // - fractional id list (may be empty)
  // - statechange id
  // - payload

  let _file: File iso
  let _filepath: FilePath
  let _event_log: EventLog
  let _writer: Writer iso
  var _replay_log_exists: Bool
  var _bytes_written: USize = 0

  new create(filepath: FilePath, event_log: EventLog) =>
    _writer = recover iso Writer end
    _filepath = filepath
    _replay_log_exists = _filepath.exists()
    _file = recover iso File(filepath) end
    _event_log = event_log

  fun ref dispose() =>
    _file.dispose()

  fun bytes_written(): U64 =>
    _bytes_written.u64()

  fun ref start_log_replay() =>
    if _replay_log_exists then
      @printf[I32](("RESILIENCE: Replaying from recovery log file: " +
        _filepath.path + "\n").cstring())

      //replay log to EventLog
      try
        let r = Reader

        //seek beginning of file
        _file.seek_start(0)
        var size = _file.size()
        _bytes_written = size

        var num_replayed: USize = 0
        var num_skipped: USize = 0

        // array to hold recovered data temporarily until we've sent it off to
        // be replayed
        var replay_buffer: Array[ReplayEntry val] ref = replay_buffer.create()

        let watermarks: Map[U128, U64] = watermarks.create()

        //start iterating until we reach original EOF
        while _file.position() < size do
          r.append(_file.read(25))
          let is_watermark = r.bool()  // 1
          let origin_id = r.u128_be()  // 16
          let seq_id = r.u64_be()      // 8
          @printf[I32]("|| NISAN seq_id: %d is_watermark: %s\n".cstring(),
            seq_id, is_watermark.string().cstring())
          if is_watermark then
            // save last watermark read from file
            watermarks(origin_id) = seq_id
          else
            r.append(_file.read(24))
            let uid = r.u128_be()  // 16
            let fractional_size = r.u64_be()  // 8
            let frac_ids = recover val
              if fractional_size > 0 then
                let bytes_to_read = fractional_size.usize() * 4
                r.append(_file.read(bytes_to_read))
                let l = Array[U32]
                for i in Range(0,fractional_size.usize()) do
                  l.push(r.u32_be())
                end
                l
              else
                //None is faster if we have no frac_ids, which will probably be
                //true most of the time
                None
              end
            end
            r.append(_file.read(16))
            let statechange_id = r.u64_be()  // 8
            let payload_length = r.u64_be()  // 8
            @printf[I32]("|| NISAN payload_length: %d\n".cstring(),
              payload_length)
            let payload = recover val
              if payload_length > 0 then
                _file.read(payload_length.usize())
              else
                Array[U8]
              end
            end
            let u' = Bytes.to_u64(payload(0), payload(1), payload(2),
            payload(3), payload(4), payload(5), payload(6), payload(7))
            @printf[I32]("||NISAN payload: %d\n".cstring(), u')

            // put entry into temporary recovered buffer
            replay_buffer.push((origin_id, uid, frac_ids, statechange_id, seq_id
              ,payload))

          end

          // clear read buffer to free file data read so far
          if r.size() > 0 then
            Fail()
          end
          r.clear()
        end

        // iterate through recovered buffer and replay entries at or below
        // watermark
        for entry in replay_buffer.values() do
          // only replay if at or below watermark
          if entry._5 <= watermarks.get_or_else(entry._1, 0) then
            num_replayed = num_replayed + 1
            _event_log.replay_log_entry(entry._1, entry._2, entry._3,
              entry._4, entry._6)
          else
            num_skipped = num_skipped + 1
          end
        end

        @printf[I32]("RESILIENCE: Replayed %d entries from recovery log file.\n"
          .cstring(), num_replayed)
        @printf[I32]("RESILIENCE: Skipped %d entries from recovery log file.\n"
          .cstring(), num_skipped)

        _file.seek_end(0)
        _event_log.log_replay_finished()
      else
        @printf[I32]("Cannot recover state from eventlog\n".cstring())
      end
    else
      @printf[I32]("RESILIENCE: Could not find log file to replay.\n"
        .cstring())
      Fail()
    end

  fun ref write(): USize ?
  =>
    let size = _writer.size()
    if not _file.writev(recover val _writer.done() end) then
      error
    else
      _bytes_written = _bytes_written + size
    end
    _bytes_written

  fun ref encode_entry(entry: LogEntry)
  =>
    (let is_watermark: Bool, let origin_id: U128,
     let uid: U128, let frac_ids: FractionalMessageId,
     let statechange_id: U64, let seq_id: U64,
     let payload: Array[ByteSeq] val) = consume entry

    ifdef "trace" then
      if is_watermark then
        @printf[I32]("Writing Watermark: %d\n".cstring(), seq_id)
      else
        @printf[I32]("Writing Message: %d\n".cstring(), seq_id)
      end
    end

    _writer.bool(is_watermark)
    _writer.u128_be(origin_id)
    _writer.u64_be(seq_id)
    @printf[I32]("||NISAN encode_entry: seq_id: %d is_watermark: %s\n"
      .cstring(), seq_id, is_watermark.string().cstring())

    if not is_watermark then
      _writer.u128_be(uid)

      match frac_ids
      | None =>
        _writer.u64_be(0)
      | let x: Array[U32] val =>
        let fractional_size = x.size().u64()
        _writer.u64_be(fractional_size)

        for frac_id in x.values() do
          _writer.u32_be(frac_id)
        end
      else
        Fail()
      end

      _writer.u64_be(statechange_id)
      var payload_size: USize = 0
      for p in payload.values() do
        payload_size = payload_size + p.size()
      end
      _writer.u64_be(payload_size.u64())
    end

    // write data to write buffer
    //_writer.u64_be(2)
    try
      let p = payload(0)
      let u' = Bytes.to_u64(p(0), p(1), p(2), p(3), p(4), p(5), p(6), p(7))
      @printf[I32]("||NISAN encode_entry writev(payload): %d\n".cstring(), u')
    end
    _writer.writev(payload)

  fun ref sync() ? =>
    _file.sync()
    match _file.errno()
    | FileOK => None
    else
      error
    end

  fun ref datasync() ? =>
    _file.datasync()
    match _file.errno()
    | FileOK => None
    else
      error
    end

class RotatingFileBackend is Backend
  // _basepath identifies the worker
  // For unique file identifier, we use the sum of payload sizes saved as a
  // U64 encoded in hex. This is maintained with _offset and
  // _backend.bytes_written()
  var _backend: FileBackend
  let _base_dir: FilePath
  let _base_name: String
  let _suffix: String
  let _event_log: EventLog
  let _file_length: (USize | None)
  var _offset: U64

  new create(base_dir: FilePath, base_name: String, suffix: String = ".evlog",
    event_log: EventLog, file_length: (USize | None)) ?
  =>
    _base_dir = base_dir
    _base_name = base_name
    _suffix = suffix
    _file_length = file_length
    _event_log = event_log

    // scan existing files matching _base_path, and identify the latest one
    // based on the hex offset
    _offset = try
      let last_file_path = LastLogFilePath(_base_name, _suffix, _base_dir)
      let parts = last_file_path.path.split("-.")
      let offset_str = parts(parts.size()-2)
      HexOffset.u64(offset_str)
    else // create a new file with offset 0
      0
    end
    let p = _base_name + "-" + HexOffset(_offset) + _suffix
    let fp = FilePath(_base_dir, p)
    _backend = FileBackend(fp, _event_log)

  fun ref sync() ? =>
    _backend.sync()

  fun ref datasync() ? =>
    _backend.datasync()

  fun ref start_log_replay() => _backend.start_log_replay()

  fun ref write(): USize ? =>
    let bytes_written = _backend.write()
    match _file_length
    | let l: USize =>
      if bytes_written >= l then
        _event_log.start_rotation()
      end
    end
    bytes_written

  fun ref encode_entry(entry: LogEntry) => _backend.encode_entry(consume entry)

  fun ref rotate_file() ? =>
    // only do this if current backend has actually written anything
    if _backend.bytes_written() > 0 then
      // 1. sync/datasync the current backend to ensure everything is written
      _backend.sync()
      _backend.datasync()
      // 2. close the file by disposing the backend
      _backend.dispose()
      // 3. update _offset
      _offset = _offset + _backend.bytes_written()
      // 4. open new backend with new file set to new offset.
      let p = _base_name + "-" + HexOffset(_offset) + _suffix
      let fp = FilePath(_base_dir, p)
      _backend = FileBackend(fp, _event_log)
    end
