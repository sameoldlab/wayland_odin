package wayland

import "base:intrinsics"

import "core:slice"
import "core:sys/linux"

import "common"
import "wl"

WAYLAND_BUFFER_SIZE :: #config(WAYLAND_BUFFER_SIZE, 1 << 12)

Connection      :: common.Connection
Object_Type     :: common.Object_Type
SERVER_ID_START :: common.SERVER_ID_START

@(require_results)
display_connect :: proc(
	socket: linux.Fd,
	allocator := context.allocator,
	log_fn: proc(message: string, user_data: rawptr) = nil,
	user_data: rawptr = nil,
) -> (connection: Connection, display: wl.Display) {
	wl.resolve_type = resolve_type

	connection.socket                 = socket
	connection.buffer_in              = make([]byte, WAYLAND_BUFFER_SIZE,    allocator)
	connection.fds_in                 = make([dynamic]linux.Fd,              allocator)
	connection.fds_out                = make([dynamic]linux.Fd,              allocator)
	connection.free_ids               = make([dynamic]u32,                   allocator)
	connection.server_object_types    = make([dynamic]common.Object_Type,    allocator)
	connection.client_object_types    = make([dynamic]common.Object_Type, 2, allocator)
	connection.client_object_types[1] = .Wl_Display
	connection.log_fn                 = log_fn
	connection.user_data              = user_data
	display                           = 1
	return
}

connection_destroy :: proc(connection: Connection) {
	delete(connection.buffer_in, connection.buffer_out.allocator)
	delete(connection.buffer_out)
	delete(connection.client_object_types)
	delete(connection.server_object_types)
	delete(connection.fds_in)
	delete(connection.fds_out)
	delete(connection.free_ids)
}

// man cmsg(3)
// man sendmsg(2)
// man unix(7)
CMsg_Hdr :: struct {
	len:         uint,
	level, type: i32,
}

// #define CMSG_ALIGN(len) ( ((len)+sizeof(long)-1) & ~(sizeof(long)-1) )
CMSG_ALIGN :: #force_inline proc "contextless" (len: $T) -> T {
	align :: int(size_of(uint) - 1)
	return (len + align) & ~align
}

// #define CMSG_LEN(len) (sizeof(struct cmsghdr) + (len))
CMSG_LEN :: #force_inline proc "contextless" (data_len: int) -> int {
	return size_of(CMsg_Hdr) + data_len
}

// #define CMSG_SPACE(len) (sizeof(struct cmsghdr) + CMSG_ALIGN(len))
CMSG_SPACE :: #force_inline proc "contextless" (data_len: $T) -> T {
	return size_of(CMsg_Hdr) + CMSG_ALIGN(data_len)
}

CMSG_FIRSTHDR :: #force_inline proc "contextless" (mhdr: ^linux.Msg_Hdr) -> ^CMsg_Hdr {
	if len(mhdr.control) >= size_of(CMsg_Hdr) {
		return (^CMsg_Hdr)(raw_data(mhdr.control))
	}
	return nil
}

SCM_RIGHTS :: 1
// Linux SCM_MAX_FD is 253, but Wayland messages are usually 0-3 within a frame
MAX_FDS :: 28
CMSG_SPACE_MAX_FDS ::
	size_of(CMsg_Hdr) + ((MAX_FDS * size_of(linux.Fd) + size_of(uint) - 1) &~ (size_of(uint) - 1))

connection_flush :: proc(connection: ^Connection) -> linux.Errno {
	if len(connection.buffer_out) == 0 && len(connection.fds_out) == 0 do return .NONE

	control_buf: [CMSG_SPACE_MAX_FDS]byte
	control: []byte
	if len(connection.fds_out) > 0 {
		assert(len(connection.fds_out) <= MAX_FDS, "too many fds queed in one flush")
		data := len(connection.fds_out) * size_of(linux.Fd)
		space := CMSG_SPACE(data)
		control = control_buf[:space]

		cmsghdr := cast(^CMsg_Hdr)raw_data(control)
		cmsghdr.len = uint(CMSG_LEN(data))
		cmsghdr.level = i32(linux.SOL_SOCKET)
		cmsghdr.type = SCM_RIGHTS

		copy(control[size_of(CMsg_Hdr):], slice.to_bytes(connection.fds_out[:]))
	}

	for len(connection.buffer_out) > 0 {
		msg := linux.Msg_Hdr {
			iov     = {{base = raw_data(connection.buffer_out), len = len(connection.buffer_out)}},
			control = control,
		}
		n, errno := linux.sendmsg(connection.socket, &msg, {.NOSIGNAL})
		if errno == .EINTR do continue

		// if errno == .EAGAIN do return 
		if errno != .NONE do return errno
		assert(n > 0)
		control = nil
		clear(&connection.fds_out)
		rest := len(connection.buffer_out) - n
		copy(connection.buffer_out[:], connection.buffer_out[n:])
		resize(&connection.buffer_out, rest)
  }
  return .NONE
}

connection_poll :: proc(connection: ^Connection) -> linux.Errno {
  // TODO!: make a better return type
	copy(connection.buffer_in, connection.buffer_in[connection.start_in:connection.end_in])
	connection.end_in = connection.end_in - connection.start_in
	connection.start_in = 0

	control_buf: [CMSG_SPACE_MAX_FDS]byte
	msg: linux.Msg_Hdr = {
		iov     = {transmute(linux.IO_Vec)connection.buffer_in[connection.end_in:]},
		control = control_buf[:],
	}

	for {
		n, errno := linux.recvmsg(connection.socket, &msg, {.CMSG_CLOEXEC })
		if errno == .EINTR do continue
		if errno == .EAGAIN do return errno 
		if errno != .NONE do return errno

		// stream closed by compositor
		if n == 0 do return .ECONNRESET

		connection.end_in += n
		break
	}

	if .CTRUNC in msg.flags do return .EMSGSIZE

	// TODO!: add macro for NXTHDR to handle multiple fds in a single message
	if hdr := CMSG_FIRSTHDR(&msg); hdr != nil {
		if hdr.level != i32(linux.SOL_SOCKET) ||
			 hdr.type != SCM_RIGHTS ||
			 hdr.len < uint(CMSG_LEN(0)) ||
			 hdr.len > uint(len(msg.control)) {
				return .EINVAL
			}

		data_len := int(hdr.len) - size_of(CMsg_Hdr)
		if data_len % size_of(linux.Fd) != 0 {
			return .EINVAL
		}

		append(
			&connection.fds_in,
			..slice.reinterpret([]linux.Fd, msg.control[size_of(hdr^):][:data_len]),
		)
	}

	return .NONE
}

@(require_results)
peek_event :: proc(connection: ^Connection) -> (event: Event, ok: bool) {
	for {
		event, ok = _peek_event(connection)
		if !ok {
			return
		}
		if deleted, ok := event.(wl.Display_Delete_Id_Event); ok {
			append(&connection.free_ids, deleted.id)
		} else {
			return
		}
	}
}

@(require_results)
_peek_event :: proc(connection: ^Connection) -> (event: Event, ok: bool) {
	if connection.end_in - connection.start_in < 8 {
		return
	}

	object: u32
	intrinsics.mem_copy(&object, &connection.buffer_in[connection.start_in], 4)
	opcode, size: u16
	intrinsics.mem_copy(&opcode, &connection.buffer_in[connection.start_in + 4], 2)
	intrinsics.mem_copy(&size,   &connection.buffer_in[connection.start_in + 6], 2)

	assert(int(size) <= len(connection.buffer_in))
	assert(size % 4 == 0)
	assert(size >= 8)

	if connection.end_in - connection.start_in < int(size) {
		return
	}

	object_type: Object_Type
	if int(object) >= SERVER_ID_START {
		object := object - SERVER_ID_START
		if int(object) >= len(connection.server_object_types) {
			return
		}
		object_type = connection.server_object_types[object]
	} else {
		if int(object) >= len(connection.client_object_types) {
			return
		}
		object_type = connection.client_object_types[object]
	}

	prev_start := connection.start_in
	defer if !ok {
		connection.start_in = prev_start
	}

	connection.start_in += 8
	return parse_event(connection, object, object_type, u32(opcode))
}
