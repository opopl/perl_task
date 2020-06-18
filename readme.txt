
Task is being implemented in Dancer2.

18.06.2020, 10:38 am

requirements completed except periodic updating
from the server. Within the time specified I did not manage
a find a solution for this within the Dancer2 web framework,
since it itself runs the built-in within a loop (dance() function at the end
of the program). I am using Windows, not Linux. Probably on Linux it is easier
to implement? 

- cache is working
= route /search/:term is working.

259 pictures were loaded at 10:48.
examples of usage:

http://localhost:3000/search/nikon
http://localhost:3000/wonderful/nikon

search is case-insensitive. 

Run on Windows 7, strawberry perl 64-bit, 5.24.4

Considerations for the requirement of periodic updates: 
	use other web-server or framework, not Dancer2 ? Use AnyEvent or $SIG{ALARM} = ...
	trick? I am using Windows, I do not have a Linux machine at home,
	probably it is easier to do in linux?

	One could also do periodic updating from outside the script, e.g.
	via crontab on linux

