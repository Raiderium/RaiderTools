module raider.tools.barrier;

import core.atomic;
static import core.sync.barrier;

/**
 * Barrier
 * 
 * Threads may only pass a barrier in groups of a specified size.
 * This implementation spins to wait, for high performance loops.
 * It can be told to wait on a condition if no work is available.
 */
class Barrier
{private:
	shared uint size;
	shared uint slots;
	shared uint souls;
	shared bool goSleep;
	core.sync.barrier.Barrier condBarrier;

public:
	/* Depending on its size, a barrier can hold back a certain number of souls.
	 * Remaining spaces for arriving souls are called slots.
	 * If no slots are available, arriving souls wait for them to become available.
	 * When all slots are filled, the barrier breaks, and souls cross one-by-one.
	 * The last to cross empties the slots and the barrier reforms.*/

	this(uint size)
	{
		this.size = size;
		slots = size;
		condBarrier = new core.sync.barrier.Barrier(size);
	}

	/* TODO Compare with core.internal.spinlock
	 * Points of note:
	 * - Cacheline alignment with align(64)
	 * - rep nop only static if (X86) (applies to all usage of rep; nop;)
	 * - Unlocks with MemoryOrder.rel ..?
	 * - Backoff strategies
	 * Perhaps spinlocking is always a bad idea for a thread barrier?
	 * Profile by comparing to a sync-primitive based implementation.
	 */
	
	void wait()
	{
		//Wait for a slot.
		uint get, set;
		do {
			get = set = atomicLoad!(MemoryOrder.raw)(slots);
			if(get) --set;
			else asm { rep; nop; } //Yield to hyperthread siblings
		}
		while(!get || !cas(&slots, get, set));

		//Wait for all souls to arrive.
		while(slots && !goSleep) { asm { rep; nop; } }
		if(goSleep) condBarrier.wait;

		//Last to leave
		if(atomicOp!"+="(souls, 1) == size)
		{
			atomicStore(souls, 0);
			atomicStore(goSleep, false);
			slots = size;
		}
	}

	/**
	 * Switches spinning threads to a CPU-friendly condition barrier.
	 * 
	 * Must be called by a thread that later crosses the barrier.
	 * After the barrier breaks, it reverts to spinning.
	 */
	void sleep()
	{
		//Wait until the last soul leaves.
		while(!slots) { asm { rep; nop; } }
		goSleep = true;
	}
}
