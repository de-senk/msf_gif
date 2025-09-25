#import,file "../module.jai";
#import "Basic";
main :: () {
    // width := 480;
    // height := 320;
    centisecondsPerFrame := 1;
    quality := 8;

    handle := New(MsfGifState);
    defer free(handle);
    image_buffer1, width, height, color_stride,is_not_stb1 :=    load_sample_image("../test_p0.jpg");
    image_buffer2:, width=, height=, color_stride=,is_not_stb2:= load_sample_image("../test_p1.jpg");
    image_buffer3:, width=, height=, color_stride=,is_not_stb3:= load_sample_image("../test_p2.jpg");
    // msf_gif_bgra_flag = true; //optionally, set this flag if your pixels are in BGRA format instead of RGBA
    // msf_gif_alpha_threshold = 128; //optionally, enable transparency (see function documentation below for details)
    msf_gif_begin  (handle=handle, width, height);
    msf_gif_frame(handle, image_buffer1.data, centisecondsPerFrame, quality, width*color_stride);
    msf_gif_frame(handle, image_buffer2.data, centisecondsPerFrame, quality, width*color_stride);
    msf_gif_frame(handle, image_buffer3.data, centisecondsPerFrame, quality, width*color_stride);
    // msf_gif_frame(handle,null, centisecondsPerFrame, quality, width/4);
    result := msf_gif_end(handle);
    export_to_gif("../test_p0.gif", result);
    log("exported file");

    free_sample_image(image_buffer1, is_not_stb1);
    free_sample_image(image_buffer2, is_not_stb2);
    free_sample_image(image_buffer3, is_not_stb3);




}

export_to_gif :: (rel_path_filename_with_extension: string, gif_result: MsfGifResult) {
    fs :: #import "File";
    out: string;
    out.data = gif_result.data;
    out.count = gif_result.dataSize;
    success := fs.write_entire_file(rel_path_filename_with_extension, out);
    assert(success);
}

load_sample_image :: (filename: string) -> image_buffer: []u8, width: int, height: int, color_stride: int, should_not_deallocate_by_stb: bool {
    fs :: #import "File";
    image :: #import "stb_image";

    should_not_deallocate_by_stb := false;
    data_raw, success := fs.read_entire_file(filename);
    assert(success);
    assert(data_raw.count != 0);
    defer free(data_raw);

    width, height, nrChannels: s32;
    img_data := image.stbi_load_from_memory(data_raw.data, xx data_raw.count, *width, *height, *nrChannels, 0);
    assert(img_data != null, "[ERROR] img_data is null");
    // assert(nrChannels == 4, "[ERROR] num channels is not 4, %",nrChannels);
    log("w % h % c %", width, height, nrChannels);

    if nrChannels == 3 //force all textures to be 4 channels
      {

        original_view:[]u8;
        original_view.data = xx img_data;
        original_view.count = width * height * 3;


        target_pointer := alloc(width * height * 4);
        target_view:[]u8;
        target_view.data = target_pointer;
        target_view.count = width * height * 4;

        strided_offset := 0;
        for original_view
        {
          strided_idx := it_index+strided_offset;
          target_view[strided_idx] = it;
          if (it_index+1) % 3 == 0
          {
            // assert();
            target_view[strided_idx+1] = 255; //set alpha to 1, I think 1 means opaque?
            strided_offset += 1;
          }
        }
        //Order is important, this should happen here
        nrChannels = 4;
        image.stbi_image_free(img_data);
        should_not_deallocate_by_stb = true;
        original_view.data = target_view.data; //UNUSED
        img_data = target_pointer; //USED BELOW

         log("reallocated image memory % and freed the previous one", strided_offset);    //reallocate to 4

      }

    image_buffer: []u8;
    image_buffer.count = width * height * 4;
    image_buffer.data = img_data;
    color_stride := nrChannels;
    return image_buffer, width, height, color_stride, should_not_deallocate_by_stb;
}

free_sample_image :: (image_buffer: []u8, is_not_stb: bool) {

    image :: #import "stb_image";
    if is_not_stb then {
        array_free(image_buffer);
    } else {
        image.stbi_image_free(image_buffer.data);
    }
}
