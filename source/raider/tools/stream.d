module raider.tools.stream;

import derelict.physfs.physfs;
import raider.tools.reference;

/**
 * Takes data from somewhere, and puts it elsewhere.
 */
abstract class Stream
{public:
	enum Mode
	{
		Write,
		Read,
		Duplex
	}
	
protected:
	void writeBytes(const(ubyte)[] bytes);
	void readBytes(ubyte[] bytes);
	
private:
	string source;
	private Mode _mode;
	private uint _bytesWritten;
	private uint _bytesRead;
	
public:
	this(string source, Mode mode)
	{
		this.source = source;
		_mode = mode;
	}
	
	final void write(T)(const(T)[] objects)
	{
		assert(writable);
		_bytesWritten += T.sizeof * objects.length;
		writeBytes((cast(const(ubyte)*)objects.ptr)[0..objects.length*T.sizeof]);
	}
	
	final void read(T)(T[] objects)
	{
		assert(readable);
		_bytesRead += T.sizeof * objects.length;
		ubyte[] bytes = (cast(ubyte*)objects.ptr)[0..objects.length*T.sizeof];
		readBytes(bytes);
	}
	
	@property uint bytesWritten() { return _bytesWritten; }
	@property uint bytesRead() { return _bytesRead; }
	@property bool writable() { return _mode == Mode.Write || _mode == Mode.Duplex; }
	@property bool readable() { return _mode == Mode.Read || _mode == Mode.Duplex; }
}

final class FileStream : Stream
{private:
	PHYSFS_File* file;
	string filename;
	
public:
	this(string filename, Mode mode)
	{
		assert(mode != Mode.Duplex);
		super(filename, mode);
		this.filename = filename;
		
		const char* cstr = (filename ~ x"00").ptr;
		file = writable ? PHYSFS_openWrite(cstr) : PHYSFS_openRead(cstr);
		
		if(file == null) throw new StreamException(
			"Couldn't open file '" ~ filename ~ "' for " ~ (writable ? "writing" : "reading"));
	}
	
	~this()
	{
		if(PHYSFS_close(file) == -1)
			throw new StreamException("Failed to close '" ~ filename ~ "'. Probably a buffered write failure.");
	}
	
	override void writeBytes(const(ubyte)[] bytes)
	{
    static if (uint.sizeof < typeof(bytes.length).sizeof)
    {
      auto offset = 0;
      auto length = bytes.length;
      while (length > 0)
      {
        uint safe_length = length % uint.max;
        auto ptr = bytes.ptr + offset;
        offset += safe_length;
        length -= safe_length;
        if(PHYSFS_write(file, cast(const(void)*)ptr, safe_length, 1U) != 1)
          throw new StreamException("Error writing to '" ~ filename ~ "'");
      }
    }
    else
    {
      if(PHYSFS_write(file, cast(const(void)*)bytes.ptr, bytes.length, 1U) != 1)
        throw new StreamException("Error writing to '" ~ filename ~ "'");
    }
	}
	
	override void readBytes(ubyte[] bytes)
	{
    static if (uint.sizeof < typeof(bytes.length).sizeof)
    {
      auto offset = 0;
      auto length = bytes.length;
      while (length > 0)
      {
        uint safe_length = length % uint.max;
        auto ptr = bytes.ptr + offset;
        offset += safe_length;
        length -= safe_length;
        if(PHYSFS_read(file, cast(void*)ptr, safe_length, 1U) != 1U)
          throw new StreamException("Error reading from '" ~ filename ~ "'");
        if(PHYSFS_eof(file))
          throw new StreamException("EOF reading from '" ~ filename ~ "'");
      }
    }
    else
    {
      if(PHYSFS_read(file, cast(void*)bytes.ptr, bytes.length, 1U) != 1U)
        throw new StreamException("Error reading from '" ~ filename ~ "'");
      if(PHYSFS_eof(file))
        throw new StreamException("EOF reading from '" ~ filename ~ "'");
    }
	}
}

final class SingularityStream : Stream
{
	this()
	{
		super("A black hole", Mode.Write);
	}
	
	override void writeBytes(const(ubyte)[] bytes)
	{
		
	}
	
	override void readBytes(ubyte[] bytes)
	{
		
	}
}

final class StreamException : Exception
{
	this(string msg)
	{
		super(msg);
	}
}
