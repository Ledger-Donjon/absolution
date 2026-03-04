#include "nbgl_obj.h"


typedef union {
    nbgl_obj_t            base;
    nbgl_container_t      container;
    nbgl_line_t           line;
    nbgl_image_t          image;
    nbgl_image_file_t     image_file;
    nbgl_qrcode_t         qrcode;
    nbgl_radio_t          radio;
    nbgl_switch_t         sw;
    nbgl_progress_bar_t   progress;
    nbgl_page_indicator_t page_ind;
    nbgl_button_t         button;
    nbgl_text_area_t      text_area;
    nbgl_text_entry_t     text_entry;
    nbgl_mask_control_t   mask;
    nbgl_spinner_t        spinner;
    nbgl_keyboard_t       keyboard;
    nbgl_keypad_t         keypad;
} nbgl_any_obj_t;

#define OBJ_POOL_SIZE 512
static nbgl_any_obj_t obj_pool[OBJ_POOL_SIZE];
