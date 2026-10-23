package web

import "core:fmt"

/*
Debug logging is compile-time switchable so hot paths pay nothing:

	odin build examples/hello -define:WEB_DEBUG=true
*/
WEB_DEBUG_ENABLED :: #config(WEB_DEBUG, false)

log_error :: proc(format: string, args: ..any) {
	fmt.eprintfln(format, ..args)
}

log_info :: proc(format: string, args: ..any) {
	fmt.printfln(format, ..args)
}

log_debug :: proc(format: string, args: ..any) {
	when WEB_DEBUG_ENABLED {
		fmt.printfln(format, ..args)
	}
}
