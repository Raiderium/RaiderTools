module raider.tools.exception;

mixin template SimpleThis()
{
	@safe pure nothrow this(
		string msg = null,
		string file = __FILE__,
		size_t line = __LINE__,
		Throwable next = null)
	{
		super(msg, file, line, next);
	}
}

/*TODO Propagate this pattern across all RaiderXX libraries.
 * final class FooException : Exception
 * { import raider.tools.exception; mixin SimpleThis; }
*/
