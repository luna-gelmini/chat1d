module chat1_replay
  use, intrinsic :: iso_fortran_env, only: int32, int64, iostat_end
  use chat1_room_engine, only: chat1_room_engine_ingest_one
  implicit none
  private
  public :: chat1_replay_log

  integer, parameter :: CHAT1_REPLAY_LINE_MAX = 8192

contains

  subroutine chat1_replay_log(path, replayed_count, ios)
    character(len=*), intent(in) :: path
    integer, intent(out) :: replayed_count
    integer, intent(out) :: ios

    character(len=CHAT1_REPLAY_LINE_MAX) :: line
    integer :: unit, read_stat, slot
    integer(int64) :: ts_ms

    replayed_count = 0
    ios = 0

    open(newunit=unit, file=path, status='old', action='read', &
         access='sequential', form='formatted', iostat=ios)
    if (ios /= 0) return

    do
      read(unit, '(A)', iostat=read_stat) line
      if (read_stat == iostat_end) exit
      if (read_stat /= 0) then
        ios = read_stat
        close(unit)
        return
      end if

      call replay_apply_line(line, ts_ms, slot, ios)
      if (ios /= 0) then
        close(unit)
        return
      end if
      if (slot > 0) replayed_count = replayed_count + 1
    end do

    close(unit)
  end subroutine chat1_replay_log

  subroutine replay_apply_line(line, ts_ms, slot, ios)
    character(len=*), intent(in) :: line
    integer(int64), intent(out) :: ts_ms
    integer, intent(out) :: slot
    integer, intent(out) :: ios

    integer :: p1, p2, p3, p4, p5, p6
    integer :: ts_stat
    character(len=:), allocatable :: kind, room, body_b64

    slot = 0
    ts_ms = 0_int64
    ios = 0

    p1 = index(line, char(9))
    if (p1 <= 0) return
    kind = line(1:p1-1)
    if (kind /= 'MSG') return

    p2 = index(line(p1+1:), char(9))
    if (p2 <= 0) return
    p2 = p1 + p2

    p3 = index(line(p2+1:), char(9))
    if (p3 <= 0) return
    p3 = p2 + p3

    p4 = index(line(p3+1:), char(9))
    if (p4 <= 0) return
    p4 = p3 + p4

    p5 = index(line(p4+1:), char(9))
    if (p5 <= 0) return
    p5 = p4 + p5

    p6 = index(line(p5+1:), char(9))
    if (p6 <= 0) return
    p6 = p5 + p6

    room = line(p1+1:p2-1)
    body_b64 = line(p5+1:p6-1)

    read(line(p4+1:p5-1), *, iostat=ts_stat) ts_ms
    if (ts_stat /= 0) then
      ios = ts_stat
      return
    end if

    call chat1_room_engine_ingest_one(room, body_b64, ts_ms, slot)
  end subroutine replay_apply_line

end module chat1_replay
