program test_room_store
  use, intrinsic :: iso_fortran_env, only: int64
  use chat1_room_store
  implicit none
  integer :: slot

  call chat1_room_store_init(8, 3)
  call chat1_room_store_append("#general", "hi   ", 5_int64, slot)

  if (slot /= 1) error stop "slot mismatch"
  call chat1_room_store_append("#general", "x", 6_int64, slot)
  if (slot /= 2) error stop "second slot mismatch"

  print *, "ok room store"
end program test_room_store
