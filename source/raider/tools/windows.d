module raider.tools.windows;

version(Windows):

public import core.sys.windows.windows;

extern(Windows)
{
	DWORD SetThreadAffinityMask(HANDLE,DWORD);
	HANDLE OpenThread(DWORD, BOOL, DWORD);
	
	enum
	{
		THREAD_ALL_ACCESS = 0x001F03FF
	}
}
