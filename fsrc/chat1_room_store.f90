module chat1_room_store
  use, intrinsic :: iso_fortran_env, only: int32, int64
  implicit none
  private
  integer(int32), parameter :: room_id_max_len = 64_int32
  public :: chat1_room_store_init, chat1_room_store_append

  integer(int32), save :: capacity = 0_int32
  integer(int32), save :: used = 0_int32
  integer(int32), save :: arena_size = 0_int32
  integer(int32), save :: arena_used = 0_int32
  integer(int64), allocatable, save :: timestamps(:)
  integer(int32), allocatable, save :: body_offsets(:)
  integer(int32), allocatable, save :: body_lengths(:)
  character(len=room_id_max_len), allocatable, save :: room_ids(:)
  character(len=:), allocatable, save :: body_arena

contains

  subroutine chat1_room_store_init(max_events, max_body_bytes)
    integer(int32), intent(in) :: max_events, max_body_bytes

    if (allocated(timestamps)) deallocate(timestamps)
    if (allocated(body_offsets)) deallocate(body_offsets)
    if (allocated(body_lengths)) deallocate(body_lengths)
    if (allocated(room_ids)) deallocate(room_ids)
    if (allocated(body_arena)) deallocate(body_arena)

    capacity = max_events
    arena_size = max_body_bytes
    used = 0_int32
    arena_used = 0_int32

    allocate(timestamps(capacity), body_offsets(capacity), body_lengths(capacity), room_ids(capacity))
    allocate(character(len=arena_size) :: body_arena)

    timestamps = 0_int64
    body_offsets = 0_int32
    body_lengths = 0_int32
    room_ids = ""
    body_arena = ""
  end subroutine chat1_room_store_init

  subroutine chat1_room_store_append(room_id, body, ts_ms, slot)
    character(len=*), intent(in) :: room_id, body
    integer(int64), intent(in) :: ts_ms
    integer, intent(out) :: slot
    integer(int32) :: body_len
    integer(int32) :: body_start
    integer(int32) :: room_len

    body_len = int(len_trim(body), int32)
    room_len = int(len_trim(room_id), int32)

    if (.not. allocated(timestamps)) error stop "room store not initialized"
    if (room_len > room_id_max_len) error stop "room id too long"
    if (used >= capacity) error stop "room store full"
    if (arena_used + body_len > arena_size) error stop "body arena full"

    used = used + 1_int32
    slot = int(used)
    body_start = arena_used + 1_int32

    timestamps(slot) = ts_ms
    room_ids(slot) = ""
    if (room_len > 0_int32) room_ids(slot)(1:room_len) = room_id(1:room_len)
    body_offsets(slot) = body_start
    body_lengths(slot) = body_len
    if (body_len > 0_int32) body_arena(body_start:body_start + body_len - 1_int32) = body(1:body_len)
    arena_used = arena_used + body_len

    call verify_room_store_entry(int(slot, int32), room_id, room_len, body, body_len, ts_ms, body_start)
  end subroutine chat1_room_store_append

  subroutine verify_room_store_entry(slot, room_id, room_len, body, body_len, ts_ms, body_start)
    integer(int32), intent(in) :: slot
    character(len=*), intent(in) :: room_id, body
    integer(int32), intent(in) :: room_len, body_len, body_start
    integer(int64), intent(in) :: ts_ms
    character(len=room_id_max_len) :: expected_room_id

    expected_room_id = ""
    if (room_len > 0_int32) expected_room_id(1:room_len) = room_id(1:room_len)

    if (timestamps(slot) /= ts_ms) error stop "timestamp write mismatch"
    if (room_ids(slot) /= expected_room_id) error stop "room id write mismatch"
    if (body_offsets(slot) /= body_start) error stop "body offset write mismatch"
    if (body_lengths(slot) /= body_len) error stop "body length write mismatch"
    if (body_len > 0_int32) then
      if (body_arena(body_start:body_start + body_len - 1_int32) /= body(1:body_len)) then
        error stop "body write mismatch"
      end if
    end if
  end subroutine verify_room_store_entry

end module chat1_room_store
