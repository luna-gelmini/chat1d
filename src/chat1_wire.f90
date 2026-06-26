module chat1_wire
  use chat1_types
  use chat1_hex
  use chat1_base64url
  use chat1_crypto
  implicit none
  private

  public :: chat1_parse_frame, chat1_encode_frame, chat1_canonical_msg_bytes, chat1_verify_msg_signature

contains

  subroutine chat1_parse_frame(raw_line, frame, err)
    character(len=*), intent(in) :: raw_line
    type(chat1_frame), intent(out) :: frame
    type(chat1_error), intent(out) :: err

    character(len=:), allocatable :: line, verb
    character(len=:), allocatable :: fields(:)

    call chat1_clear_frame(frame)
    call chat1_clear_error(err)

    call strip_input_line(raw_line, line, err)
    if (.not. err%ok) return

    if (len(line) > CHAT1_MAX_LINE_LEN) then
      call chat1_set_error(err, 'too-large', 'frame exceeds line limit')
      return
    end if

    call split_frame(line, verb, fields, err)
    if (.not. err%ok) return

    select case (verb)
    case ('HELLO')
      if (size(fields) /= 4) then
        call chat1_set_error(err, 'bad-frame', 'HELLO field count mismatch')
        return
      end if
      call parse_hello(fields, frame, err)
    case ('MSG')
      if (size(fields) /= 6) then
        call chat1_set_error(err, 'bad-frame', 'MSG field count mismatch')
        return
      end if
      call parse_msg(fields, frame, err)
    case ('WANT')
      if (size(fields) /= 2) then
        call chat1_set_error(err, 'bad-frame', 'WANT field count mismatch')
        return
      end if
      call parse_want(fields, frame, err)
    case ('ERR')
      if (size(fields) /= 2) then
        call chat1_set_error(err, 'bad-frame', 'ERR field count mismatch')
        return
      end if
      call parse_err(fields, frame, err)
    case default
      call chat1_set_error(err, 'unsupported-command', 'unsupported command')
    end select
  end subroutine chat1_parse_frame

  subroutine chat1_encode_frame(frame, line, err)
    type(chat1_frame), intent(in) :: frame
    character(len=:), allocatable, intent(out) :: line
    type(chat1_error), intent(out) :: err

    call chat1_clear_error(err)
    line = ''

    select case (frame%kind)
    case (CHAT1_KIND_HELLO)
      line = 'HELLO' // achar(9) // CHAT1_VERSION // achar(9) // frame%hello%node_id // achar(9) // &
             frame%hello%pubkey_b64 // achar(9) // frame%hello%mode
    case (CHAT1_KIND_MSG)
      line = 'MSG' // achar(9) // frame%msg%room_id // achar(9) // frame%msg%msg_id // achar(9) // &
             frame%msg%author_id // achar(9) // frame%msg%ts_ms // achar(9) // frame%msg%body_b64 // achar(9) // &
             frame%msg%sig_b64
    case (CHAT1_KIND_WANT)
      line = 'WANT' // achar(9) // frame%want%room_id // achar(9) // frame%want%since_id
    case (CHAT1_KIND_ERR)
      line = 'ERR' // achar(9) // frame%err%err_code // achar(9) // frame%err%err_text
    case default
      call chat1_set_error(err, 'bad-frame', 'cannot encode unknown frame kind')
    end select
  end subroutine chat1_encode_frame

  subroutine chat1_canonical_msg_bytes(msg, canonical, err)
    type(msg_frame), intent(in) :: msg
    character(len=:), allocatable, intent(out) :: canonical
    type(chat1_error), intent(out) :: err

    call chat1_clear_error(err)
    canonical = 'msg' // new_line('a') // msg%room_id // new_line('a') // msg%author_id // new_line('a') // &
                msg%ts_ms // new_line('a') // msg%body_b64 // new_line('a')
  end subroutine chat1_canonical_msg_bytes

  subroutine chat1_verify_msg_signature(msg, pubkey_b64, is_valid, err)
    type(msg_frame), intent(in) :: msg
    character(len=*), intent(in) :: pubkey_b64
    logical, intent(out) :: is_valid
    type(chat1_error), intent(out) :: err

    character(len=:), allocatable :: canonical, derived_node_id
    type(chat1_error) :: local_err

    call chat1_clear_error(err)
    is_valid = .false.

    call chat1_canonical_msg_bytes(msg, canonical, local_err)
    if (.not. local_err%ok) then
      err = local_err
      return
    end if

    call chat1_sha256_b64url(pubkey_b64, derived_node_id, local_err)
    if (.not. local_err%ok) then
      err = local_err
      return
    end if
    if (trim(derived_node_id) /= trim(msg%author_id)) then
      call chat1_set_error(err, 'bad-node-id', 'author_id does not match public key')
      return
    end if

    call chat1_verify_ed25519(pubkey_b64, msg%sig_b64, canonical, is_valid, local_err)
    if (.not. local_err%ok) then
      err = local_err
      return
    end if
    if (.not. is_valid) call chat1_set_error(err, 'bad-signature', 'signature verification failed')
  end subroutine chat1_verify_msg_signature

  subroutine parse_hello(fields, frame, err)
    character(len=*), intent(in) :: fields(:)
    type(chat1_frame), intent(inout) :: frame
    type(chat1_error), intent(out) :: err

    character(len=:), allocatable :: derived_node_id
    type(chat1_error) :: local_err

    call chat1_clear_error(err)

    if (trim(fields(1)) /= CHAT1_VERSION) then
      call chat1_set_error(err, 'unsupported-version', 'unsupported protocol version')
      return
    end if
    if (.not. chat1_is_lower_hex(trim(fields(2)), CHAT1_NODE_ID_LEN)) then
      call chat1_set_error(err, 'bad-node-id', 'invalid node_id format')
      return
    end if
    if (len_trim(fields(3)) /= CHAT1_PUBKEY_B64_LEN) then
      call chat1_set_error(err, 'bad-frame', 'invalid pubkey length')
      return
    end if
    if (.not. chat1_is_base64url_unpadded(trim(fields(3)))) then
      call chat1_set_error(err, 'bad-frame', 'invalid pubkey base64url')
      return
    end if
    if (.not. is_valid_mode(trim(fields(4)))) then
      call chat1_set_error(err, 'bad-frame', 'invalid mode')
      return
    end if

    call chat1_sha256_b64url(trim(fields(3)), derived_node_id, local_err)
    if (.not. local_err%ok) then
      err = local_err
      return
    end if
    if (trim(derived_node_id) /= trim(fields(2))) then
      call chat1_set_error(err, 'bad-node-id', 'node_id does not match pubkey')
      return
    end if

    frame%kind = CHAT1_KIND_HELLO
    frame%hello%node_id = trim(fields(2))
    frame%hello%pubkey_b64 = trim(fields(3))
    frame%hello%mode = trim(fields(4))
  end subroutine parse_hello

  subroutine parse_msg(fields, frame, err)
    character(len=*), intent(in) :: fields(:)
    type(chat1_frame), intent(inout) :: frame
    type(chat1_error), intent(out) :: err

    character(len=:), allocatable :: body_text, canonical, derived_msg_id
    type(chat1_error) :: local_err

    call chat1_clear_error(err)

    if (.not. is_valid_room_id(trim(fields(1)))) then
      call chat1_set_error(err, 'bad-room', 'invalid room_id')
      return
    end if
    if (.not. chat1_is_lower_hex(trim(fields(2)), CHAT1_MSG_ID_LEN)) then
      call chat1_set_error(err, 'bad-msg-id', 'invalid msg_id format')
      return
    end if
    if (.not. chat1_is_lower_hex(trim(fields(3)), CHAT1_NODE_ID_LEN)) then
      call chat1_set_error(err, 'bad-node-id', 'invalid author_id format')
      return
    end if
    if (.not. chat1_is_decimal_uint(trim(fields(4)))) then
      call chat1_set_error(err, 'bad-frame', 'invalid ts_ms format')
      return
    end if
    if (.not. chat1_is_base64url_unpadded(trim(fields(5)))) then
      call chat1_set_error(err, 'bad-frame', 'invalid body base64url')
      return
    end if
    if (len_trim(fields(6)) /= CHAT1_SIG_B64_LEN) then
      call chat1_set_error(err, 'bad-frame', 'invalid signature length')
      return
    end if
    if (.not. chat1_is_base64url_unpadded(trim(fields(6)))) then
      call chat1_set_error(err, 'bad-frame', 'invalid signature base64url')
      return
    end if

    call chat1_base64url_decode(trim(fields(5)), body_text, local_err)
    if (.not. local_err%ok) then
      err = local_err
      return
    end if
    if (len(body_text) < 1 .or. len(body_text) > CHAT1_MAX_BODY_BYTES) then
      call chat1_set_error(err, 'too-large', 'decoded body length out of range')
      return
    end if
    if (.not. is_valid_utf8(body_text)) then
      call chat1_set_error(err, 'bad-frame', 'decoded body is not valid UTF-8')
      return
    end if

    frame%kind = CHAT1_KIND_MSG
    frame%msg%room_id = trim(fields(1))
    frame%msg%msg_id = trim(fields(2))
    frame%msg%author_id = trim(fields(3))
    frame%msg%ts_ms = trim(fields(4))
    frame%msg%body_b64 = trim(fields(5))
    frame%msg%body_text = body_text
    frame%msg%sig_b64 = trim(fields(6))

    call chat1_canonical_msg_bytes(frame%msg, canonical, local_err)
    if (.not. local_err%ok) then
      err = local_err
      return
    end if
    call chat1_sha256_text(canonical, derived_msg_id, local_err)
    if (.not. local_err%ok) then
      err = local_err
      return
    end if
    if (trim(derived_msg_id) /= trim(frame%msg%msg_id)) then
      call chat1_set_error(err, 'bad-msg-id', 'msg_id does not match canonical bytes')
      return
    end if
  end subroutine parse_msg

  subroutine parse_want(fields, frame, err)
    character(len=*), intent(in) :: fields(:)
    type(chat1_frame), intent(inout) :: frame
    type(chat1_error), intent(out) :: err

    call chat1_clear_error(err)

    if (.not. is_valid_room_id(trim(fields(1)))) then
      call chat1_set_error(err, 'bad-room', 'invalid room_id')
      return
    end if
    if (trim(fields(2)) /= '-' .and. .not. chat1_is_lower_hex(trim(fields(2)), CHAT1_MSG_ID_LEN)) then
      call chat1_set_error(err, 'bad-frame', 'invalid since_id')
      return
    end if

    frame%kind = CHAT1_KIND_WANT
    frame%want%room_id = trim(fields(1))
    frame%want%since_id = trim(fields(2))
  end subroutine parse_want

  subroutine parse_err(fields, frame, err)
    character(len=*), intent(in) :: fields(:)
    type(chat1_frame), intent(inout) :: frame
    type(chat1_error), intent(out) :: err

    call chat1_clear_error(err)

    if (.not. is_valid_err_code(trim(fields(1)))) then
      call chat1_set_error(err, 'bad-frame', 'invalid error code')
      return
    end if
    if (.not. is_valid_text_field(fields(2))) then
      call chat1_set_error(err, 'bad-frame', 'invalid error text field')
      return
    end if

    frame%kind = CHAT1_KIND_ERR
    frame%err%err_code = trim(fields(1))
    frame%err%err_text = trim(fields(2))
  end subroutine parse_err

  subroutine strip_input_line(raw_line, line, err)
    character(len=*), intent(in) :: raw_line
    character(len=:), allocatable, intent(out) :: line
    type(chat1_error), intent(out) :: err

    integer :: n

    call chat1_clear_error(err)
    line = raw_line
    n = len(line)

    if (n > 0 .and. line(n:n) == new_line('a')) then
      line = line(1:n-1)
      n = len(line)
    end if
    if (n > 0 .and. line(n:n) == achar(13)) then
      line = line(1:n-1)
    end if
    if (index(line, achar(13)) /= 0) then
      call chat1_set_error(err, 'bad-frame', 'raw CR not allowed inside frame')
      return
    end if
    if (index(line, new_line('a')) /= 0) then
      call chat1_set_error(err, 'bad-frame', 'raw LF not allowed inside frame')
    end if
  end subroutine strip_input_line

  subroutine split_frame(line, verb, fields, err)
    character(len=*), intent(in) :: line
    character(len=:), allocatable, intent(out) :: verb
    character(len=:), allocatable, intent(out) :: fields(:)
    type(chat1_error), intent(out) :: err

    integer :: first_tab, num_tabs, i, start_pos, end_pos, max_len

    call chat1_clear_error(err)
    verb = ''

    first_tab = index(line, achar(9))
    if (first_tab == 0) then
      call chat1_set_error(err, 'bad-frame', 'missing field separator')
      return
    end if

    verb = line(1:first_tab-1)
    if (.not. is_uppercase_ascii(verb)) then
      call chat1_set_error(err, 'bad-frame', 'verb must be uppercase ASCII')
      return
    end if

    num_tabs = count_tabs(line)
    max_len = len(line)
    allocate(character(len=max_len) :: fields(num_tabs))
    fields = ''

    start_pos = first_tab + 1
    do i = 1, num_tabs
      if (i < num_tabs) then
        end_pos = index(line(start_pos:), achar(9))
        if (end_pos == 0) then
          fields(i) = line(start_pos:)
          start_pos = len(line) + 1
        else
          fields(i) = line(start_pos:start_pos+end_pos-2)
          start_pos = start_pos + end_pos
        end if
      else
        if (start_pos <= len(line)) then
          fields(i) = line(start_pos:)
        else
          fields(i) = ''
        end if
      end if
    end do
  end subroutine split_frame

  logical function is_valid_room_id(value) result(ok)
    character(len=*), intent(in) :: value
    integer :: i, n, code

    n = len_trim(value)
    ok = .false.
    if (n < 1 .or. n > CHAT1_MAX_ROOM_LEN) return

    ok = .true.
    do i = 1, n
      code = iachar(value(i:i))
      if (.not. ((code >= iachar('A') .and. code <= iachar('Z')) .or. &
                 (code >= iachar('a') .and. code <= iachar('z')) .or. &
                 (code >= iachar('0') .and. code <= iachar('9')) .or. &
                 value(i:i) == '.' .or. value(i:i) == '_' .or. value(i:i) == '#' .or. value(i:i) == '-')) then
        ok = .false.
        return
      end if
    end do
  end function is_valid_room_id

  logical function is_valid_mode(value) result(ok)
    character(len=*), intent(in) :: value

    ok = trim(value) == CHAT1_MODE_PEER .or. trim(value) == CHAT1_MODE_HUB .or. trim(value) == CHAT1_MODE_PEER_HUB
  end function is_valid_mode

  logical function is_valid_err_code(value) result(ok)
    character(len=*), intent(in) :: value
    integer :: i, n, code

    n = len_trim(value)
    ok = .false.
    if (n < 1 .or. n > CHAT1_MAX_ERR_CODE_LEN) return

    ok = .true.
    do i = 1, n
      code = iachar(value(i:i))
      if (.not. ((code >= iachar('a') .and. code <= iachar('z')) .or. &
                 (code >= iachar('0') .and. code <= iachar('9')) .or. value(i:i) == '-')) then
        ok = .false.
        return
      end if
    end do
  end function is_valid_err_code

  logical function is_valid_text_field(value) result(ok)
    character(len=*), intent(in) :: value

    ok = index(value, achar(9)) == 0 .and. index(value, achar(13)) == 0 .and. index(value, new_line('a')) == 0
  end function is_valid_text_field

  logical function is_uppercase_ascii(value) result(ok)
    character(len=*), intent(in) :: value
    integer :: i, n, code

    n = len_trim(value)
    ok = .false.
    if (n < 1 .or. n > 16) return

    ok = .true.
    do i = 1, n
      code = iachar(value(i:i))
      if (code < iachar('A') .or. code > iachar('Z')) then
        ok = .false.
        return
      end if
    end do
  end function is_uppercase_ascii

  integer function count_tabs(text) result(total)
    character(len=*), intent(in) :: text
    integer :: i

    total = 0
    do i = 1, len(text)
      if (text(i:i) == achar(9)) total = total + 1
    end do
  end function count_tabs

  logical function is_valid_utf8(text) result(ok)
    character(len=*), intent(in) :: text
    integer :: i, n, b1, b2, b3, b4

    ok = .true.
    n = len(text)
    i = 1
    do while (i <= n)
      b1 = iachar(text(i:i))
      if (b1 <= int(z'7F')) then
        i = i + 1
      else if (b1 >= int(z'C2') .and. b1 <= int(z'DF')) then
        if (i + 1 > n) then
          ok = .false.; return
        end if
        b2 = iachar(text(i+1:i+1))
        if (b2 < int(z'80') .or. b2 > int(z'BF')) then
          ok = .false.; return
        end if
        i = i + 2
      else if (b1 >= int(z'E0') .and. b1 <= int(z'EF')) then
        if (i + 2 > n) then
          ok = .false.; return
        end if
        b2 = iachar(text(i+1:i+1))
        b3 = iachar(text(i+2:i+2))
        if (b2 < int(z'80') .or. b2 > int(z'BF') .or. b3 < int(z'80') .or. b3 > int(z'BF')) then
          ok = .false.; return
        end if
        if (b1 == int(z'E0') .and. b2 < int(z'A0')) then
          ok = .false.; return
        end if
        if (b1 == int(z'ED') .and. b2 > int(z'9F')) then
          ok = .false.; return
        end if
        i = i + 3
      else if (b1 >= int(z'F0') .and. b1 <= int(z'F4')) then
        if (i + 3 > n) then
          ok = .false.; return
        end if
        b2 = iachar(text(i+1:i+1))
        b3 = iachar(text(i+2:i+2))
        b4 = iachar(text(i+3:i+3))
        if (b2 < int(z'80') .or. b2 > int(z'BF') .or. b3 < int(z'80') .or. b3 > int(z'BF') .or. &
            b4 < int(z'80') .or. b4 > int(z'BF')) then
          ok = .false.; return
        end if
        if (b1 == int(z'F0') .and. b2 < int(z'90')) then
          ok = .false.; return
        end if
        if (b1 == int(z'F4') .and. b2 > int(z'8F')) then
          ok = .false.; return
        end if
        i = i + 4
      else
        ok = .false.
        return
      end if
    end do
  end function is_valid_utf8

end module chat1_wire
