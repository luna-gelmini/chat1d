module chat1_hex
  use chat1_types, only: chat1_error, chat1_clear_error, chat1_set_error
  implicit none
  private

  public :: chat1_is_lower_hex, chat1_is_decimal_uint, chat1_int_to_string

contains

  logical function chat1_is_lower_hex(value, expected_len) result(ok)
    character(len=*), intent(in) :: value
    integer, intent(in) :: expected_len
    integer :: i, code

    ok = .false.
    if (len_trim(value) /= expected_len) return

    ok = .true.
    do i = 1, expected_len
      code = iachar(value(i:i))
      if (.not. ((code >= iachar('0') .and. code <= iachar('9')) .or. &
                 (code >= iachar('a') .and. code <= iachar('f')))) then
        ok = .false.
        return
      end if
    end do
  end function chat1_is_lower_hex

  logical function chat1_is_decimal_uint(value) result(ok)
    character(len=*), intent(in) :: value
    integer :: i, code, n

    n = len_trim(value)
    ok = .false.
    if (n < 1) return
    if (n > 1 .and. value(1:1) == '0') return

    ok = .true.
    do i = 1, n
      code = iachar(value(i:i))
      if (code < iachar('0') .or. code > iachar('9')) then
        ok = .false.
        return
      end if
    end do
  end function chat1_is_decimal_uint

  function chat1_int_to_string(value) result(text)
    integer, intent(in) :: value
    character(len=:), allocatable :: text
    character(len=32) :: buffer

    write(buffer, '(I0)') value
    text = trim(buffer)
  end function chat1_int_to_string

end module chat1_hex
