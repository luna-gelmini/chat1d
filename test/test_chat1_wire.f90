program test_chat1_wire
  use chat1_types
  use chat1_crypto
  use chat1_wire
  implicit none

  integer :: failures
  logical :: ok
  type(chat1_error) :: err

  failures = 0

  call chat1_crypto_selftest(ok, err)
  call assert_true(ok .and. err%ok, 'crypto backend selftest', failures)

  call test_hello_valid(failures)
  call test_hello_bad_node_id(failures)
  call test_hello_bad_mode(failures)
  call test_want_valid(failures)
  call test_err_valid(failures)
  call test_msg_valid(failures)
  call test_msg_bad_msg_id(failures)
  call test_msg_bad_sig(failures)
  call test_msg_bad_body_utf8(failures)
  call test_bad_frame_wrong_arity(failures)
  call test_bad_frame_raw_cr(failures)
  call test_bad_frame_padded_base64(failures)

  if (failures > 0) then
    write(*, '(A,I0)') 'FAIL ', failures
    error stop 1
  end if

  write(*, '(A)') 'OK chat1 tests'

contains

  subroutine test_hello_valid(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err
    character(len=:), allocatable :: line, encoded

    line = read_fixture('test/fixtures/hello_valid.txt')
    call chat1_parse_frame(line, frame, err)
    call assert_true(err%ok, 'parse hello_valid', failures)
    call assert_true(frame%kind == CHAT1_KIND_HELLO, 'hello kind', failures)
    call chat1_encode_frame(frame, encoded, err)
    call assert_true(err%ok, 'encode hello_valid', failures)
    call assert_equal(encoded, line, 'roundtrip hello_valid', failures)
  end subroutine test_hello_valid

  subroutine test_hello_bad_node_id(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err

    call chat1_parse_frame(read_fixture('test/fixtures/hello_bad_node_id.txt'), frame, err)
    call assert_false(err%ok, 'reject hello_bad_node_id', failures)
    call assert_equal(trim(err%code), 'bad-node-id', 'hello_bad_node_id code', failures)
  end subroutine test_hello_bad_node_id

  subroutine test_hello_bad_mode(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err

    call chat1_parse_frame(read_fixture('test/fixtures/hello_bad_mode.txt'), frame, err)
    call assert_false(err%ok, 'reject hello_bad_mode', failures)
    call assert_equal(trim(err%code), 'bad-frame', 'hello_bad_mode code', failures)
  end subroutine test_hello_bad_mode

  subroutine test_want_valid(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err
    character(len=:), allocatable :: line, encoded

    line = read_fixture('test/fixtures/want_valid_dash.txt')
    call chat1_parse_frame(line, frame, err)
    call assert_true(err%ok, 'parse want_valid_dash', failures)
    call chat1_encode_frame(frame, encoded, err)
    call assert_true(err%ok, 'encode want_valid_dash', failures)
    call assert_equal(encoded, line, 'roundtrip want_valid_dash', failures)

    line = read_fixture('test/fixtures/want_valid_msgid.txt')
    call chat1_parse_frame(line, frame, err)
    call assert_true(err%ok, 'parse want_valid_msgid', failures)
    call chat1_encode_frame(frame, encoded, err)
    call assert_true(err%ok, 'encode want_valid_msgid', failures)
    call assert_equal(encoded, line, 'roundtrip want_valid_msgid', failures)
  end subroutine test_want_valid

  subroutine test_err_valid(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err
    character(len=:), allocatable :: line, encoded

    line = read_fixture('test/fixtures/err_valid.txt')
    call chat1_parse_frame(line, frame, err)
    call assert_true(err%ok, 'parse err_valid', failures)
    call chat1_encode_frame(frame, encoded, err)
    call assert_true(err%ok, 'encode err_valid', failures)
    call assert_equal(encoded, line, 'roundtrip err_valid', failures)
  end subroutine test_err_valid

  subroutine test_msg_valid(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err
    character(len=:), allocatable :: line, encoded
    logical :: is_valid

    line = read_fixture('test/fixtures/msg_valid.txt')
    call chat1_parse_frame(line, frame, err)
    call assert_true(err%ok, 'parse msg_valid', failures)
    call chat1_encode_frame(frame, encoded, err)
    call assert_true(err%ok, 'encode msg_valid', failures)
    call assert_equal(encoded, line, 'roundtrip msg_valid', failures)

    call chat1_verify_msg_signature(frame%msg, 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg', is_valid, err)
    call assert_true(is_valid .and. err%ok, 'verify msg_valid signature', failures)
  end subroutine test_msg_valid

  subroutine test_msg_bad_msg_id(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err

    call chat1_parse_frame(read_fixture('test/fixtures/msg_bad_msg_id.txt'), frame, err)
    call assert_false(err%ok, 'reject msg_bad_msg_id', failures)
    call assert_equal(trim(err%code), 'bad-msg-id', 'msg_bad_msg_id code', failures)
  end subroutine test_msg_bad_msg_id

  subroutine test_msg_bad_sig(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err
    logical :: is_valid

    call chat1_parse_frame(read_fixture('test/fixtures/msg_bad_sig.txt'), frame, err)
    call assert_true(err%ok, 'parse msg_bad_sig shape', failures)
    call chat1_verify_msg_signature(frame%msg, 'A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg', is_valid, err)
    call assert_false(is_valid, 'reject msg_bad_sig verify', failures)
    call assert_false(err%ok, 'msg_bad_sig returns error', failures)
    call assert_equal(trim(err%code), 'bad-signature', 'msg_bad_sig code', failures)
  end subroutine test_msg_bad_sig

  subroutine test_msg_bad_body_utf8(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err

    call chat1_parse_frame(read_fixture('test/fixtures/msg_bad_body_utf8.txt'), frame, err)
    call assert_false(err%ok, 'reject msg_bad_body_utf8', failures)
    call assert_equal(trim(err%code), 'bad-frame', 'msg_bad_body_utf8 code', failures)
  end subroutine test_msg_bad_body_utf8

  subroutine test_bad_frame_wrong_arity(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err

    call chat1_parse_frame(read_fixture('test/fixtures/bad_frame_wrong_arity.txt'), frame, err)
    call assert_false(err%ok, 'reject bad_frame_wrong_arity', failures)
    call assert_equal(trim(err%code), 'bad-frame', 'bad_frame_wrong_arity code', failures)
  end subroutine test_bad_frame_wrong_arity

  subroutine test_bad_frame_raw_cr(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err

    call chat1_parse_frame(read_fixture('test/fixtures/bad_frame_raw_cr.txt'), frame, err)
    call assert_false(err%ok, 'reject bad_frame_raw_cr', failures)
    call assert_equal(trim(err%code), 'bad-frame', 'bad_frame_raw_cr code', failures)
  end subroutine test_bad_frame_raw_cr

  subroutine test_bad_frame_padded_base64(failures)
    integer, intent(inout) :: failures
    type(chat1_frame) :: frame
    type(chat1_error) :: err

    call chat1_parse_frame(read_fixture('test/fixtures/bad_frame_padded_base64.txt'), frame, err)
    call assert_false(err%ok, 'reject bad_frame_padded_base64', failures)
    call assert_equal(trim(err%code), 'bad-frame', 'bad_frame_padded_base64 code', failures)
  end subroutine test_bad_frame_padded_base64

  function read_fixture(path) result(text)
    character(len=*), intent(in) :: path
    character(len=:), allocatable :: text
    integer :: unit, ios, size_bytes

    inquire(file=path, size=size_bytes, iostat=ios)
    if (ios /= 0) error stop 'cannot stat fixture'
    allocate(character(len=size_bytes) :: text)

    open(newunit=unit, file=path, access='stream', form='unformatted', status='old', action='read', iostat=ios)
    if (ios /= 0) error stop 'cannot open fixture'
    read(unit, iostat=ios) text
    close(unit)
    if (ios /= 0) error stop 'cannot read fixture'
  end function read_fixture

  subroutine assert_true(condition, label, failures)
    logical, intent(in) :: condition
    character(len=*), intent(in) :: label
    integer, intent(inout) :: failures
    if (.not. condition) then
      failures = failures + 1
      write(*, '(A,A)') 'not ok: ', trim(label)
    end if
  end subroutine assert_true

  subroutine assert_false(condition, label, failures)
    logical, intent(in) :: condition
    character(len=*), intent(in) :: label
    integer, intent(inout) :: failures
    call assert_true(.not. condition, label, failures)
  end subroutine assert_false

  subroutine assert_equal(left, right, label, failures)
    character(len=*), intent(in) :: left
    character(len=*), intent(in) :: right
    character(len=*), intent(in) :: label
    integer, intent(inout) :: failures
    call assert_true(left == right, label, failures)
  end subroutine assert_equal

end program test_chat1_wire
