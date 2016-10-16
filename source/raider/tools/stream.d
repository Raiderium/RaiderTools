module raider.tools.stream;

import raider.tools.reference;
import raider.tools.array;
import std.range;
import std.traits;
import std.conv : to;

/**
 * Takes data from somewhere, and puts it elsewhere.
 */
abstract class Stream
{private:
	string source; //Describes the remote endpoint
	string activity; //Describes what is being written or read
	Mode _mode;

protected:
	ulong _bytesWritten, _bytesRead;
	
public:
	enum Mode { Write, Read, Duplex }

	this(string source, Mode mode)
	{
		this.source = source;
		_mode = mode;
	}

	@property ulong bytesWritten() { return _bytesWritten; }
	@property ulong bytesRead() { return _bytesRead; }
	@property bool writable() { return _mode == Mode.Write || _mode == Mode.Duplex; }
	@property bool readable() { return _mode == Mode.Read || _mode == Mode.Duplex; }
	@property Mode mode() { return _mode; }

protected:
	void writeBytes(const(ubyte)[] bytes);
	void readBytes(ubyte[] bytes);

public:

	/**
	 * Write something to the stream.
	 * 
	 * If an item defines pack(), it will be invoked
	 * on the stream. Otherwise, it is written as it
	 * appears in memory.
	 * 
	 * All tools.reference reference types will be 
	 * dereferenced so that the referent is written 
	 * and read. When reading, they will be default
	 * constructed then unpack()'d. The same goes
	 * for native class types.
	 * 
	 * A tools.array Array will be written as a uint
	 * size then an array of items. On reading, it
	 * automatically resizes and reads them back.
	 * 
	 * A native range will be written and read as 
	 * a fixed size, as if each item were written 
	 * or read separately.
	 */

	final void write(T, Args...)(const(T) that, auto ref Args args)
	{
		assert(writable);

		static if(isInstanceOf!(Array, T))
		{
			write(that.size);
			write(that[]);
		}
		else static if(isRandomAccessRange!T)
		{
			alias ET = ElementType!T;
			auto size = ET.sizeof * that.length;

			static if(hasMember!(ET, "pack"))
				foreach(ref ET p; that) p.pack(P!Stream(this), args);
			else
			{
				writeBytes((cast(const(ubyte)*)that.ptr)[0..size]);
				_bytesWritten += size;
			}
		}
		else write((&that)[0..1]);
	}


	final void read(T, Args...)(ref T that, auto ref Args args)
	{
		assert(readable);

		static if(isInstanceOf!(Array, T))
		{
			uint size; read(size);
			that.size = size;
			auto tmp = that[];
			read(tmp, args);
		}
		else static if(isRandomAccessRange!T)
		{
			alias ET = ElementType!T;

			static if(is(ET == class))
				foreach(ref ET p; that) p = New!ET();

			static if(hasMember!(ET, "unpack"))
				foreach(ref ET p; that) p.unpack(P!Stream(this), args);
			else
			{
				auto size = ET.sizeof * that.length;
				readBytes((cast(ubyte*)that.ptr)[0..size]);
				_bytesRead += size;
			}
		}
		else
		{
			auto tmp = (&that)[0..1];
			read(tmp, args);
		}
	}

	T read(T)()
	{
		T tmp; read(tmp);
		return tmp;
	}
}


import std.stdio;

final class FileStream : Stream
{private:
	File file;
	string filename;
	
public:
	this(string filename, Mode mode)
	{
		assert(mode != Mode.Duplex);
		super(filename, mode);
		this.filename = filename;

		file = File(filename, writable ? "w" : "r");
		if(!file.isOpen) throw new StreamException(
			"Couldn't open file '" ~ filename ~ "' for " ~ (writable ? "writing" : "reading"));
	}
	
	~this()
	{
		try { file.close(); } catch(Exception e)
		{ throw new StreamException("Failed to close '" ~ filename ~ "'. Media disconnected?"); }
	}
	
	override void writeBytes(const(ubyte)[] bytes)
	{
		try { file.rawWrite(bytes); } catch(Exception e)
		{ throw new StreamException("Writing to '" ~ filename ~ "' failed"); }
	}

	override void readBytes(ubyte[] bytes)
	{
		ubyte[] tmp;
		try { tmp = file.rawRead(bytes); } catch(Exception e)
			throw new StreamException("Reading from '" ~ filename ~ "' failed");
		if(tmp.length < bytes.length)
			throw new StreamException("EOF reading from '" ~ filename ~ "'");
	}

	/**
	 * Move the cursor a relative distance.
	 */
	void skip(long offset)
	{
		try { file.seek(offset, SEEK_CUR); } catch(Exception e)
			throw new StreamException("Skipping " ~ to!string(offset) ~ " bytes in '" ~ filename ~ "' failed");
	}

	/**
	 * Move the cursor to an absolute position.
	 * 
	 * Negative offsets seek backward from the end of the file.
	 */
	void seek(long offset)
	{
		try
		{
			if(offset < 0) file.seek(offset, SEEK_END);
			else file.seek(offset, SEEK_SET);
		}
		catch(Exception e)
			throw new StreamException("Seeking to absolute position " ~ to!string(offset) ~ "in '" ~ filename ~ "' failed");
		_bytesWritten = offset;
		_bytesRead = offset;
	}

	ulong size()
	{
		auto tmp = tell;
		try { file.seek(0, SEEK_END); } catch(Exception e)
			throw new StreamException("Finding size of file '" ~ filename ~ "' failed");
		auto result = file.tell;
		file.seek(tmp);
		return result;
	}

	@property ulong tell()
	{
		ulong result;
		try { result = file.tell; } catch(Exception e)
			throw new StreamException("Telling in '" ~ filename ~ "' failed");
		return result;
	}
}

final class SingularityStream : Stream
{
	this() { super("A black hole", Mode.Write); }
	override void writeBytes(const(ubyte)[] bytes) { }
	override void readBytes(ubyte[] bytes) { }
	void reset() { _bytesWritten = 0; }
}

package R!SingularityStream singularity;
static this() { singularity = New!SingularityStream(); }

/**
 * Transmits over an IP network.
 * 
 * Network streams depend on a separate networking
 * component that exposes a 'path' between hosts.
 * Multiple streams may link through a path and are
 * very lightweight.
 * 
 * The networking component multiplexes content
 * from multiple NetworkStreams into a single TCP
 * socket. NetworkStreams can then be created and
 * destroyed rapidly without touching the socket.
 */
final class NetworkStream : Stream
{
	this()
	{
		super("", Mode.Duplex);
	}

	override void writeBytes(const(ubyte)[] bytes) { }
	override void readBytes(ubyte[] bytes) { }
}

/**
 * Implements a circular buffer.
 */
final class MemoryStream : Stream
{
	this()
	{
		super("", Mode.Duplex);
	}

	override void writeBytes(const(ubyte)[] bytes) { }
	override void readBytes(ubyte[] bytes) { }
}

final class StreamException : Exception
{ import raider.tools.exception; mixin SimpleThis; }


/*
 * Regarding seeking.
 * 
 * Seeking is a privilege, not a right. If a format requires seeking
 * to the end of the stream, that format is a self-obsessed layabout
 * and isn't worth our time.
 * 
 * If a format requires seeking backwards, that format is probably a
 * poorly designed format.
 */
