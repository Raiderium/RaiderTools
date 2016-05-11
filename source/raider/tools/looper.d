module raider.tools.looper;

import core.thread;
import core.time;

/**
 * Controls a game loop.
 * 
 * looper.start;
 * while(looper.running)
 * {
 *     while(looper.step)
 *     {
 *         step(looper.stepSize);
 *     }
 *     draw();
 *     looper.sleep;
 * }
 * 
 * Use looper.frameTime to interpolate graphics between the last two logic updates.
 */
class Looper
{private:
	ulong time = 0; // Game time elapsed in microseconds since start()
	ulong logicTime = 0; ///Logical time elapsed in microseconds since start()
	ulong realTime = 0; ///Real time elapsed in microseconds since start()
	int steps = 0; ///Substeps taken
	int stepMax = 8; ///Substep (aka frame skip) limit.
	double timeScale = 1.0; ///Game time elapsed in seconds for every real second
	ulong logicDelta = 16667; ///Game time between logic updates in microseconds
	bool _running;
	TickDuration tdStart;

	//Advances real time and returns microseconds of game time
	ulong realStep()
	{
		ulong now = (TickDuration.currSystemTick - tdStart).usecs;
		double result = cast(double)(now - realTime);
		realTime = now;
		return cast(ulong)(result*timeScale);
	}

public:

	@property bool running()
	{
		return _running;
	}

	@property void running(bool value)
	{
		_running = false;
	}

	@property void hertz(uint value)
	{
		logicDelta = 1000_000 / value;
	}

	@property double stepSize()
	{
		return cast(double)(logicDelta) / 1000.0;
	}

	///Graphical frame interpolation factor
	@property double frameTime()
	{
		return 1.0 - cast(double)(logicTime - time) / cast(double)logicDelta;
	}

	void start()
	{
		time = 0;
		logicTime = 0;
		realTime = 0;
		steps = 0;
		tdStart = TickDuration.currSystemTick;
	}

	bool step()
	{
		if(!_running) return false;

		time += realStep();

		//If logic is behind time..
		if(logicTime < time)
		{
			//If substeps remain
			if(steps < stepMax)
			{
				steps++;
				logicTime += logicDelta;
				return true;
			}
			else //Logic is unrecoverably slow. Jump back in time.
			{
				time = logicTime;
			}
		}

		return false;
	}

	void sleep()
	{
		//Sleep until real time matches game time
		long overTime = logicTime - time;
		if(0 < overTime)
		{
			Thread.sleep(dur!"usecs"(overTime));
		}

		//Using vsync is optimal.
		steps = 0;
	}
}
