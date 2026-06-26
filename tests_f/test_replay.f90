program test_replay
  use, intrinsic :: iso_fortran_env, only: int64
  use chat1_room_engine, only: chat1_room_engine_init
  use chat1_replay, only: chat1_replay_log
  implicit none

  character(len=*), parameter :: log_path = '/tmp/chat1-replay-test.log'
  character(len=1) :: tab
  integer :: unit, ios, replayed
  character(len=:), allocatable :: rec1, rec2, rec_bad

  tab = char(9)

  rec1 = 'MSG' // tab // '#general' // tab // 'aaaa' // tab // &
         'auth1' // tab // '1770000000001' // tab // 'aGVsbG8' // tab // 'sig1'
  rec2 = 'MSG' // tab // '#random' // tab // 'bbbb' // tab // &
         'auth2' // tab // '1770000000002' // tab // 'd29ybGQ' // tab // 'sig2'
  rec_bad = 'NOPE' // tab // 'should-be-ignored'

  open(newunit=unit, file=log_path, status='replace', action='write', &
       form='formatted', iostat=ios)
  if (ios /= 0) error stop 'cannot create test log'
  write(unit, '(A)') rec1
  write(unit, '(A)') rec2
  write(unit, '(A)') rec_bad
  close(unit)

  call chat1_room_engine_init(64, 4096)
  call chat1_replay_log(log_path, replayed, ios)
  if (ios /= 0) error stop 'replay failed'
  if (replayed /= 2) error stop 'replay count mismatch'

  print *, 'ok replay'
end program test_replay
