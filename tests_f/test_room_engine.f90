program test_room_engine
  use, intrinsic :: iso_c_binding, only: c_int32_t
  use, intrinsic :: iso_fortran_env, only: int64
  use chat1_room_engine
  implicit none
  integer :: stored

  call chat1_room_engine_init(16, 4096)
  call chat1_room_engine_ingest_one("#general", "hello rock world", 1770000123456_int64, stored)

  if (stored /= 1) error stop "ingest failed"

  call chat1_room_engine_init_c(8_c_int32_t, 32_c_int32_t)
  call chat1_room_engine_ingest_one("#tiny", "abc", 1770000123457_int64, stored)

  if (stored /= 1) error stop "c init bridge failed"

  print *, "ok room engine"
end program test_room_engine
