import argparse
import numpy as np
from PIL import Image, ImageFile


def generate_random_jpeg(output_path, width, height, quality, optimize):
    # Pillow needs a large enough internal buffer when optimize=True.
    ImageFile.MAXBLOCK = max(ImageFile.MAXBLOCK, 3 * width * height)

    data = np.random.randint(0, 256, (height, width, 3), dtype=np.uint8)
    img = Image.fromarray(data, mode="RGB")
    img.save(
        output_path,
        format="JPEG",
        quality=quality,
        optimize=optimize,
        subsampling=0,
        progressive=False,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Generate a random JPEG image."
    )
    parser.add_argument("output_path", type=str, help="Output JPEG file path.")
    parser.add_argument("width", type=int, help="Image width.")
    parser.add_argument("height", type=int, help="Image height.")
    parser.add_argument("quality", type=int, help="JPEG quality (0-100).")
    parser.add_argument(
        "--optimize", action="store_true", help="Enable JPEG optimize"
    )

    args = parser.parse_args()

    generate_random_jpeg(
        args.output_path, args.width, args.height, args.quality, args.optimize
    )
