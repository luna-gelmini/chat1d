program test_engine_ingest
  use, intrinsic :: iso_c_binding
  use chat1_room_engine, only: chat1_room_engine_init, chat1_engine_ingest_batch, &
                                chat1_ingress_event_t, chat1_ingress_batch_t, &
                                CHAT1_BODY_BYTES, CHAT1_ROOM_ID_BYTES
  implicit none

  type(chat1_ingress_batch_t), target :: batch
  integer(c_int32_t), target :: fanout_dummy
  integer(c_int32_t) :: rc, fanout_count
  character(len=*), parameter :: room = '#general'
  character(len=*), parameter :: body = 'aGVsbG8'
  integer :: i

  call chat1_room_engine_init(64, 4096)

  batch%shard_index = 0_c_int32_t
  batch%local_count = 1_c_int32_t

  batch%events(1)%connection_id = 0_c_int64_t
  batch%events(1)%room_hash = 0_c_int64_t
  batch%events(1)%ts_ms = 1770000000123_c_int64_t
  batch%events(1)%body_len = int(len(body), c_int32_t)

  do i = 1, CHAT1_ROOM_ID_BYTES
    batch%events(1)%room_id(i) = c_null_char
  end do
  do i = 1, len(room)
    batch%events(1)%room_id(i) = room(i:i)
  end do

  do i = 1, CHAT1_BODY_BYTES
    batch%events(1)%body_b64(i) = c_null_char
  end do
  do i = 1, len(body)
    batch%events(1)%body_b64(i) = body(i:i)
  end do

  rc = chat1_engine_ingest_batch(c_loc(batch), c_loc(fanout_dummy), fanout_count)
  if (rc /= 0_c_int32_t) error stop 'engine ingest returned non-OK'
  if (fanout_count /= 0_c_int32_t) error stop 'fanout_count expected 0'

  rc = chat1_engine_ingest_batch(c_null_ptr, c_loc(fanout_dummy), fanout_count)
  if (rc == 0_c_int32_t) error stop 'engine ingest accepted null batch'

  rc = chat1_engine_ingest_batch(c_loc(batch), c_null_ptr, fanout_count)
  if (rc == 0_c_int32_t) error stop 'engine ingest accepted null fanout'

  print *, 'ok engine ingest'
end program test_engine_ingest
