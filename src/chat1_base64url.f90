module chat1_base64url
  use chat1_types, only: chat1_error, chat1_clear_error, chat1_set_error
  implicit none
  private

  public :: chat1_is_base64url_unpadded, chat1_base64url_decode, chat1_base64url_encode

contains

  logical function chat1_is_base64url_unpadded(value) result(ok)
    character(len=*), intent(in) :: value
    integer :: i, code, n

    n = len_trim(value)
    ok = .false.
    if (n < 1) return
    if (index(value(1:n), '=') /= 0) return

    ok = .true.
    do i = 1, n
      code = iachar(value(i:i))
      if (.not. ((code >= iachar('A') .and. code <= iachar('Z')) .or. &
                 (code >= iachar('a') .and. code <= iachar('z')) .or. &
                 (code >= iachar('0') .and. code <= iachar('9')) .or. &
                 value(i:i) == '-' .or. value(i:i) == '_')) then
        ok = .false.
        return
      end if
    end do
  end function chat1_is_base64url_unpadded

  subroutine chat1_base64url_decode(value, decoded, err)
    character(len=*), intent(in) :: value
    character(len=:), allocatable, intent(out) :: decoded
    type(chat1_error), intent(out) :: err

    integer :: n, i, out_len, pos
    integer :: v1, v2, v3, v4

    call chat1_clear_error(err)
    if (allocated(decoded)) deallocate(decoded)

    n = len_trim(value)
    if (.not. chat1_is_base64url_unpadded(value(1:n))) then
      call chat1_set_error(err, 'bad-frame', 'invalid base64url field')
      decoded = ''
      return
    end if

    if (mod(n, 4) == 1) then
      call chat1_set_error(err, 'bad-frame', 'invalid base64url length')
      decoded = ''
      return
    end if

    out_len = (n / 4) * 3
    if (mod(n, 4) == 2) out_len = out_len + 1
    if (mod(n, 4) == 3) out_len = out_len + 2

    allocate(character(len=out_len) :: decoded)
    if (out_len > 0) decoded = repeat(' ', out_len)

    pos = 1
    i = 1
    do while (i <= n)
      v1 = b64_index(value(i:i))
      v2 = b64_index(value(i+1:i+1))
      decoded(pos:pos) = achar(ior(shiftl(v1, 2), shiftr(v2, 4)))
      pos = pos + 1

      if (i + 2 <= n) then
        v3 = b64_index(value(i+2:i+2))
        decoded(pos:pos) = achar(iand(ior(shiftl(iand(v2, 15), 4), shiftr(v3, 2)), 255))
        pos = pos + 1
      else
        exit
      end if

      if (i + 3 <= n) then
        v4 = b64_index(value(i+3:i+3))
        decoded(pos:pos) = achar(iand(ior(shiftl(iand(v3, 3), 6), v4), 255))
        pos = pos + 1
      else
        exit
      end if

      i = i + 4
    end do
  end subroutine chat1_base64url_decode

  function chat1_base64url_encode(value) result(encoded)
    character(len=*), intent(in) :: value
    character(len=:), allocatable :: encoded

    character(len=*), parameter :: alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
    integer :: n, full_groups, rem, out_len, i, pos
    integer :: b1, b2, b3, chunk

    n = len(value)
    full_groups = n / 3
    rem = mod(n, 3)
    out_len = full_groups * 4
    if (rem == 1) out_len = out_len + 2
    if (rem == 2) out_len = out_len + 3

    allocate(character(len=out_len) :: encoded)
    encoded = ''

    pos = 1
    do i = 1, full_groups
      b1 = iachar(value((i-1)*3+1:(i-1)*3+1))
      b2 = iachar(value((i-1)*3+2:(i-1)*3+2))
      b3 = iachar(value((i-1)*3+3:(i-1)*3+3))
      chunk = shiftl(b1, 16) + shiftl(b2, 8) + b3
      encoded(pos:pos)     = alphabet(shiftr(chunk, 18)+1:shiftr(chunk, 18)+1)
      encoded(pos+1:pos+1) = alphabet(iand(shiftr(chunk, 12), 63)+1:iand(shiftr(chunk, 12), 63)+1)
      encoded(pos+2:pos+2) = alphabet(iand(shiftr(chunk, 6), 63)+1:iand(shiftr(chunk, 6), 63)+1)
      encoded(pos+3:pos+3) = alphabet(iand(chunk, 63)+1:iand(chunk, 63)+1)
      pos = pos + 4
    end do

    if (rem == 1) then
      b1 = iachar(value(n:n))
      encoded(pos:pos)     = alphabet(shiftr(shiftl(b1, 16), 18)+1:shiftr(shiftl(b1, 16), 18)+1)
      encoded(pos+1:pos+1) = alphabet(iand(shiftr(shiftl(b1, 16), 12), 63)+1:iand(shiftr(shiftl(b1, 16), 12), 63)+1)
    else if (rem == 2) then
      b1 = iachar(value(n-1:n-1))
      b2 = iachar(value(n:n))
      chunk = shiftl(b1, 16) + shiftl(b2, 8)
      encoded(pos:pos)     = alphabet(shiftr(chunk, 18)+1:shiftr(chunk, 18)+1)
      encoded(pos+1:pos+1) = alphabet(iand(shiftr(chunk, 12), 63)+1:iand(shiftr(chunk, 12), 63)+1)
      encoded(pos+2:pos+2) = alphabet(iand(shiftr(chunk, 6), 63)+1:iand(shiftr(chunk, 6), 63)+1)
    end if
  end function chat1_base64url_encode

  integer function b64_index(ch) result(idx)
    character(len=1), intent(in) :: ch
    integer :: code

    code = iachar(ch)
    if (code >= iachar('A') .and. code <= iachar('Z')) then
      idx = code - iachar('A')
    else if (code >= iachar('a') .and. code <= iachar('z')) then
      idx = 26 + code - iachar('a')
    else if (code >= iachar('0') .and. code <= iachar('9')) then
      idx = 52 + code - iachar('0')
    else if (ch == '-') then
      idx = 62
    else
      idx = 63
    end if
  end function b64_index

end module chat1_base64url
