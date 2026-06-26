module chat1_room_engine
  use, intrinsic :: iso_c_binding
  use, intrinsic :: iso_fortran_env, only: int32, int64
  use chat1_room_store, only: chat1_room_store_init, chat1_room_store_append
  implicit none
  private
  public :: chat1_room_engine_init, chat1_room_engine_ingest_one, &
            chat1_engine_ingest_batch, chat1_room_engine_init_c, &
            chat1_ingress_event_t, chat1_ingress_batch_t, &
            CHAT1_MAX_BATCH, CHAT1_ROOM_ID_BYTES, CHAT1_BODY_BYTES, &
            CHAT1_HEX_BYTES, CHAT1_SIG_BYTES

  integer, parameter :: CHAT1_MAX_BATCH = 256
  integer, parameter :: CHAT1_ROOM_ID_BYTES = 65
  integer, parameter :: CHAT1_BODY_BYTES = 4097
  integer, parameter :: CHAT1_HEX_BYTES = 65
  integer, parameter :: CHAT1_SIG_BYTES = 87

  integer(c_int32_t), parameter :: CHAT1_ROUTE_OK = 0_c_int32_t
  integer(c_int32_t), parameter :: CHAT1_ROUTE_ERR_INVALID = -1_c_int32_t

  type, bind(C) :: chat1_ingress_event_t
    integer(c_int64_t) :: connection_id
    integer(c_int64_t) :: room_hash
    integer(c_int64_t) :: ts_ms
    integer(c_int32_t) :: body_len
    character(kind=c_char) :: room_id(CHAT1_ROOM_ID_BYTES)
    character(kind=c_char) :: body_b64(CHAT1_BODY_BYTES)
    character(kind=c_char) :: author_id(CHAT1_HEX_BYTES)
    character(kind=c_char) :: msg_id(CHAT1_HEX_BYTES)
    character(kind=c_char) :: sig_b64(CHAT1_SIG_BYTES)
  end type chat1_ingress_event_t

  type, bind(C) :: chat1_ingress_batch_t
    integer(c_int32_t) :: shard_index
    integer(c_int32_t) :: local_count
    type(chat1_ingress_event_t) :: events(CHAT1_MAX_BATCH)
  end type chat1_ingress_batch_t

contains

  subroutine chat1_room_engine_init(max_events, max_body_bytes)
    integer, intent(in) :: max_events, max_body_bytes

    call chat1_room_store_init(int(max_events, int32), int(max_body_bytes, int32))
  end subroutine chat1_room_engine_init

  subroutine chat1_room_engine_init_c(max_events, max_body_bytes) bind(C, name="chat1_room_engine_init_c")
    integer(c_int32_t), value, intent(in) :: max_events, max_body_bytes

    call chat1_room_store_init(int(max_events, int32), int(max_body_bytes, int32))
  end subroutine chat1_room_engine_init_c

  subroutine chat1_room_engine_ingest_one(room_id, body, ts_ms, stored_slot)
    character(len=*), intent(in) :: room_id, body
    integer(int64), intent(in) :: ts_ms
    integer, intent(out) :: stored_slot

    call chat1_room_store_append(room_id, body, ts_ms, stored_slot)
  end subroutine chat1_room_engine_ingest_one

  function chat1_engine_ingest_batch(batch_ptr, fanout_ptr, fanout_count) &
      bind(C, name="chat1_engine_ingest_batch") result(rc)
    type(c_ptr), value, intent(in) :: batch_ptr
    type(c_ptr), value, intent(in) :: fanout_ptr
    integer(c_int32_t), intent(out) :: fanout_count
    integer(c_int32_t) :: rc

    type(chat1_ingress_batch_t), pointer :: batch
    integer :: i, slot, body_len_i
    character(len=:), allocatable :: room_id, body

    fanout_count = 0_c_int32_t

    if (.not. c_associated(batch_ptr)) then
      rc = CHAT1_ROUTE_ERR_INVALID
      return
    end if

    if (.not. c_associated(fanout_ptr)) then
      rc = CHAT1_ROUTE_ERR_INVALID
      return
    end if

    call c_f_pointer(batch_ptr, batch)

    if (batch%local_count < 0_c_int32_t .or. batch%local_count > int(CHAT1_MAX_BATCH, c_int32_t)) then
      rc = CHAT1_ROUTE_ERR_INVALID
      return
    end if

    do i = 1, int(batch%local_count)
      room_id = c_chars_until_null(batch%events(i)%room_id)
      body_len_i = int(batch%events(i)%body_len)
      body = c_chars_n(batch%events(i)%body_b64, body_len_i)
      call chat1_room_store_append(room_id, body, batch%events(i)%ts_ms, slot)
    end do

    rc = CHAT1_ROUTE_OK
  end function chat1_engine_ingest_batch

  function c_chars_until_null(arr) result(s)
    character(kind=c_char), intent(in) :: arr(:)
    character(len=:), allocatable :: s
    integer :: i, n

    n = 0
    do i = 1, size(arr)
      if (arr(i) == c_null_char) exit
      n = n + 1
    end do

    if (n == 0) then
      allocate(character(len=0) :: s)
    else
      allocate(character(len=n) :: s)
      do i = 1, n
        s(i:i) = arr(i)
      end do
    end if
  end function c_chars_until_null

  function c_chars_n(arr, n) result(s)
    character(kind=c_char), intent(in) :: arr(:)
    integer, intent(in) :: n
    character(len=:), allocatable :: s
    integer :: i, take

    take = n
    if (take < 0) take = 0
    if (take > size(arr)) take = size(arr)

    if (take == 0) then
      allocate(character(len=0) :: s)
      return
    end if

    allocate(character(len=take) :: s)
    do i = 1, take
      s(i:i) = arr(i)
    end do
  end function c_chars_n

end module chat1_room_engine
