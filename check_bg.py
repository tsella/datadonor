from PIL import Image
img = Image.open('logo.jpg')
print(img.getpixel((0,0)))
