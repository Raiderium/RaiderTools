module raider.tools.parallel;

import core.atomic;
import core.thread;
import core.cpuid;
import raider.tools.array;
import raider.tools.barrier;

version(Windows)
{
	import core.sys.windows.windows;
	extern(Windows) DWORD SetThreadAffinityMask(HANDLE,DWORD);
}

package int tid = -1;

__gshared
{
	package int tidMax;
	void delegate() work;
	Barrier barrier;
	Array!Thread threads;
}

//Worker threads run this function.
void worker()
{
	while(true)
	{
		barrier.wait;
		if(work) work(); else break; //TODO ethics
		barrier.wait;
	}
}

/**
 * Execute a task in parallel.
 * 
 * Call only from the main thread.
 */
public void parallelTask(void delegate() task)
{
	assert(tid == 0);
	assert(work is null);
	
	work = task;
	barrier.wait;
	work();
	barrier.wait;
	work = null;
}

shared static this()
{
	//Start worker threads.
	tidMax = threadsPerCPU;
	tid = 0; //Main thread has tid 0.
	barrier = new Barrier(tidMax);

	foreach(x; 1..tidMax)
	{
		Thread thread = new Thread(&worker).start;
		thread.isDaemon = true;
		threads.add(thread);
	}

	//Initialise tid and set core affinity
	shared int _tid = 0;

	parallelTask(
		delegate void()
		{
			if(tid == -1) tid = atomicOp!"+="(_tid, 1);

			//Lock to core
			version(Windows)
			{
				if(!SetThreadAffinityMask(GetCurrentThread(), 1u << tid))
					assert(false, "Failed to set thread affinity");
			}
		});

	//Put workers to sleep.
	barrier.sleep;
}

shared static ~this()
{ //Stop workers.
	assert(work is null);
	barrier.wait;
	foreach(thread; threads) thread.join;
}

/**
 * Put parallel workers to sleep.
 * 
 * Call only from the main thread.
 */
void parallelSleep()
{
	barrier.sleep;
}

/*
 * This actually concludes the entire thread-per-core worker system.
 * Parallel for-each is implemented on top.
 */

public:

/**
 * Parallel for-each.
 * 
 * Operates on the Array type only.
 * Does not provide the index of items.
 * 
 * foreach(item; parallel(array)) {  }
 * 
 * unit is how many elements to process between load
 * balances. For expensive loop bodies with variable
 * complexity, use 1. For cheap loop bodies use high
 * numbers, or 0 to use the highest possible number,
 * creating one unit per core, for number crunching.
 * 
 * sleep makes threads sleep rather than spin-wait.
 * This is usually preferable. Spin waiting is only
 * useful with small, carefully balanced workloads.
 * 
 * Call parallel() from the main thread only.
 * Workers cannot create new tasks.
 */
auto parallel(T)(ref Array!T array, size_t unit = 0, bool sleep = true)
{
	struct ParallelForeach //yer a wizard harry
	{ //you're a hairy wizard
		T* data;
		size_t size;
		size_t unit;
		bool sleep;
		
		int delegate(ref T) the_delegate;
		
		shared size_t x;
		
		void the_loop()
		{
			//Warm start
			size_t x0 = unit * tid;
			size_t x1 = x0 + unit;
			
			while(true)
			{
				if(x0 >= size) break;
				if(x1 > size) x1 = size;
				foreach(i; x0..x1) the_delegate(data[i]);
				
				x1 = atomicOp!"+="(x, unit);
				x0 = x1 - unit;
			}
		}
		
		int opApply(int delegate(ref T) dg)
		{
			//Ceiling division
			if(unit == 0) unit = (size / tidMax) + (size % tidMax != 0);
			
			//Warm start
			x = tidMax * unit;
			
			the_delegate = dg;
			parallelTask(&the_loop);
			if(sleep) parallelSleep;
			return 0;
		}
	} //it's funny because this is a voldemort type
	//laugh at my jokes >:(

	ParallelForeach pf = {array.ptr, array.size, unit, sleep};
	return pf;
}

//TODO Implement mixin-based parallel() to remove delegate invocation overhead
//TODO Revert to sane parallel() when the mixin becomes a mind-melting super-mistake

unittest
{
	Array!int a1 = Array!int(1,2,3,4,5,6,7,8);
	foreach(ref i; parallel(a1)) i++;
	assert(a1 == [2,3,4,5,6,7,8,9]);
}

/* About worker-local storage
 * 
 * Thread-local stuff is allocated for every D thread, and
 * is thus quite difficult to allocate per class instance.
 * Whenever a new thread appears, all instances are forced
 * to reallocate, even if the new thread has no bearing on
 * the class and is outside the pool of worker threads.
 * 
 * Well I say forced, it's rarely implemented in practice.
 * 
 * This module allows classes to create thread-local stuff
 * only for worker threads, and not have to reallocate for
 * unrelated threads. They simply create fixed-size arrays
 * on construction, with the guarantee that worker threads
 * will neither appear nor disappear in their lifespan.
 * 
 * I refer to those arrays as worker-local member storage.
 * 
 * To provide worker-local members, each thread has an ID.
 * This traditional TLS variable is initialised as invalid
 * on external threads. For those in the pool, their ID is
 * an index into the fixed-size arrays on class instances.
 * 
 * The ID is tools.parallel.tid.
 * The size of the arrays is tools.parallel.tidMax.
 */
