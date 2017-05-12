module raider.tools.looper;

import core.thread;
import core.time;
import std.conv;

/**
 * Controls a game loop.
 * 
 * looper.start;
 * while(looper.loop)
 * {
 *     while(looper.step)
 *     {
 *         step();
 *     }
 *     draw();
 *     if(vsync) vsync();
 *     else looper.sleep;
 * }
 * 
 * Use looper.frameTime to interpolate graphics between the last two logic updates
 */
class Looper
{private:
	//All times are in microseconds
	ulong logicTime = 0; 		//Logical time elapsed
	ulong logicDelta = 16667; 	//Logical time elapsed per step
	ulong logicMax = 100000; 	//Maximum time between draws (limits catch-up steps)
	bool  logicForce;			//Prevents logicMax from preventing at least 1 step
	ulong logicStart;

	bool _running;

	MonoTime timeStart;
public:

	@property ulong time()
	{
		ulong result;
		(MonoTime.currTime - timeStart).split!"usecs"(result);
		return result;
	}

	@property bool running()
	{
		return _running;
	}

	@property void logicFrequency(uint value)
	{
		logicDelta = 1000_000 / value;
	}

	/**
	 * Time elapsed per step, in seconds.
	 */
	@property double stepSize()
	{
		return cast(double)(logicDelta) / 1000000.0;
	}




	/**
	 * Step interpolation factor (inter-frame time)
	 * 
	 * Implementing a draw routine with interpolation can 
	 * be quite challenging, but it has many benefits.
	 * Most notably, it allows the game to run smoothly
	 * with different graphical and logical frequencies.
	 * 
	 * It also allows true motion blur, though combining 
	 * the two is nontrivial, since a logical update may
	 * intersect the duration of a frame.
	 * 
	 * If the logical and graphical frequencies match, this 
	 * should always be roughly 1.0. 
	 */
	@property double frameTime()
	{
		//double sif = 1.0 - cast(double)(logicTime - time) / cast(double)logicDelta;
		//assert(0.0 <= sif && sif <= 1.0, "invalid frameTime of "~to!string(sif));
		return 1.0;
	}

	/*
	 * Question: If logical and graphical frequencies match,
	 * and the game is performing well, why wouldn't it always 
	 * give SIF = 1.0?
	 * 
	 * To support motion blur, indicate frame times to draw,
	 * and when to start and stop accumulating. */

	void start()
	{
		_running = true;
		logicTime = 0;
		timeStart = MonoTime.currTime;
	}

	bool step()
	{
		if(!_running) return false;

		//If logic is behind time..
		if(logicTime < time)
		{
			//If substeps remain
			if( (time - logicStart) < logicMax)
			{
				logicTime += logicDelta;
				return true;
			}
			else //Logic is unrecoverably slow. Jump through time.
			{
				logicTime = time;
			}
		}

		return false;
	}

	bool loop()
	{
		logicStart = time;
		return _running;
	}

	void stop()
	{
		_running = false;
	}

	/**
	 * Sleep until the next logic update is due.
	 * 
	 * This will busy-wait if the thread under-sleeps,
	 * a necessary evil to provide correct behaviour.
	 * 
	 * If vsync is on, this shouldn't be called.
	 */
	void sleep()
	{
		//Sleep to catch up to the logic time
		long overTime = logicTime - time;

		if(0 < overTime)
		{
			//Thread.sleep(dur!"usecs"(overTime));
			Thread.sleep(overTime.usecs);
			//Absorb undersleep - punish imprecision
			while(time <= logicTime) asm { rep; nop; }
		}
	}
}
