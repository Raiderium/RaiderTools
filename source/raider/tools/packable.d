module raider.tools.packable;

import std.traits;
import raider.tools.stream;
import raider.tools.array;
import raider.tools.reference;

/**
 * Interface for objects that can be serialised and deserialised.
 * 
 * Serialisation of objects, also known as marshalling, persisting, 
 * flattening, pickling and shelving, is referred to as 'packing'.
 * 
 * Mainly because it's shorter and sounds (slightly) less violent.
 * 
 * Structs may implement these methods for compile-time binding.
 */
interface Packable
{
	/**
	 * Write the object to a stream.
	 * 
	 * Must not modify the object.
	 * Must propagate stream exceptions - catch and rethrow or use scope(failure).
	 */
	void pack(P!Stream) const;

	/**
	 * Read the object from a stream.
	 * 
	 * Object guaranteed to be default constructed, or in some other valid state.
	 * Must leave the object in a valid state.
	 * Must propagate stream exceptions - catch and rethrow or use scope(failure).
	 */
	void unpack(P!Stream);

	/**
	 * Estimate a packed size in bytes.
	 * 
	 * Useful for highly processed packs, like lossy audio and compressed data.
	 * Return 0 to indicate the pack is closer to a direct binary dump.
	 */
	size_t estimatePack();
}

/**
 * Asynchronous packing tool.
 * 
 * Packer provides (a)synchronous packing and unpacking of packable objects.
 * To participate, a class implements the Packable interface. Structs 
 * implement the same methods, to be resolved at compile time.
 * 
 * Pack progress is tracked by how many bytes have been processed.
 * If a packable implementation has minimal computation and is close 
 * to being a direct binary dump, estimatePack should return 0. This
 * will calculate the exact size via a dry run.
 * 
 * If an object has a complex serialised form (e.g. image and sound
 * formats) with a processor-intensive toPack, it may implement 
 * estimatePackSize to return a non-zero value.
 */
final class Packer
{
private:
	R!Packable packable;
	R!Stream stream;
	Stream.Mode _mode;

	ulong headOffset;
	ulong packOffset;
	ulong packSize;
	bool packSizeEstimated;

	bool _ready;
	Exception _exception;
	string _activity;

public:

	this(R!Packable packable, R!Stream stream, Stream.Mode mode)
	{
		assert(mode != Stream.Mode.Duplex);
		assert(stream.mode == Stream.Mode.Duplex || stream.mode == mode);

		this.packable = packable;
		this.stream = stream;
		this._mode = mode;

		headOffset = 0;
		packOffset = 0;
		packSize = 0;
		packSizeEstimated = false;

		_ready = false;
		_exception = null;
		_activity = "nothing";
	}
	
	/**
	 * Send 'em packing.
	 * 
	 * If block is true, it runs the task in the calling thread,
	 * and all exceptions are thrown from there.
	 * 
	 * If false, it is run on a background thread. Exceptions
	 * are caught and accessed later as @property exception(). 
	 */
	void start(bool block)
	{
		if(block)
		{
			run;
			if(_exception) throw _exception;
		}
		else
		{
			run;
		}
	}
	
	void run()
	{
		try
		{
			if(_mode == Stream.Mode.Write)
			{
				//Estimate or measure the packed size as appropriate.
				packSize = packable.estimatePack;

				if(packSize == 0)
				{
					singularity.reset;
					packable.pack(cast(P!Stream)singularity);
					packSize = singularity.bytesWritten;
				}
				else packSizeEstimated = true;

				//Packer writes a header containing the size.
				headOffset = stream.bytesWritten;
				stream.write(packSize);

				//Write the pack.
				packOffset = stream.bytesWritten;
				packable.pack(stream.p);

				//Find the real packed size
				if(packSizeEstimated) packSize = stream.bytesWritten - packOffset;

				//In a filestream, we update the header to reflect the real size.
				auto fs = cast(R!FileStream)stream;
				if(fs && packSizeEstimated)
				{
					fs.seek(headOffset);
					stream.write(packSize);
					fs.seek(packOffset + packSize);
				}
			}
			else
			{
				headOffset = stream.bytesRead;
				stream.read(packSize);
				packOffset = stream.bytesRead;
				packable.unpack(stream.p);
			}
			_ready = true;
		}
		catch(Exception e)
		{
			_exception = e;
		}
	}
	
public:
	@property Stream.Mode mode() { return _mode; }
	@property bool ready() { return _ready; }
	@property bool error() { return _exception ? true : false; }
	@property Exception exception() { return _exception; }
	@property double progress()
	{
		return cast(double) (_mode == Stream.Mode.Write ? stream.bytesWritten : stream.bytesRead - packOffset) / packSize; 
	}
	@property string activity() { return _activity; }
	@property void activity(string value) { _activity = value; }
}

//final class PackException : Exception
//{ import raider.tools.exception; mixin SimpleThis; }

/* TODO Update tests
//Bug prevents compilation of UnittestB (depends on A) inside the unit test.
//http://d.puremagic.com/issues/show_bug.cgi?id=852

version(unittest)
{
	final class UnittestA : Packable
	{
		int[] array;
		int[3] tuple;
		double single;
		
		this()
		{
			array = [1,2,3,4,5];
			tuple = [6,7,8];
			single = 12.345678;
		}
		
		void zero()
		{
			array = [];
			tuple = [0,0,0];
			single = 0.0;
		}
		
		override void toPack(P!Pack pack)
		{
			pack.writeArray(array);
			pack.writeTuple(tuple);
			pack.write(single);
		}

		override void fromPack(P!Pack pack)
		{
			pack.readArray(array);
			pack.readTuple(tuple);
			pack.read(single);
		}
	}

	final class UnittestB : Packable
	{
		UnittestA[] array;
		
		this()
		{
			array = [new UnittestA, new UnittestA, new UnittestA];
			array[0].single = 0.0;
			array[0].array = [0,0];
			array[1].single = 1.1;
			array[1].array = [1,1];
			array[2].single = 2.2;
			array[2].array = [2,2];
		}
		
		void zero()
		{
			array = [];
		}
		
		void toPack(P!Pack pack)
		{
			pack.writeArray(array);
		}

		void fromPack(P!Pack pack)
		{
			pack.readArray(array);
		}
	}
}

unittest
{
	UnittestA a = new UnittestA();
	a.save("TestPackableA");
	a.zero;
	a.load("TestPackableA");
	
	assert(a.array == [1,2,3,4,5]);
	assert(a.tuple == [6,7,8]);
	assert(a.single == 12.345678);
	
	
	UnittestB b = new UnittestB();
	b.save("TestPackableB");
	b.zero;
	b.load("TestPackableB");
	
	assert(b.array[1].single == 1.1);
	assert(b.array[1].array == [1,1]);
	assert(b.array.length == 3);
}
*/
