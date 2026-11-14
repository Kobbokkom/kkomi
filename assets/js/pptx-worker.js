import {
  getSlideSize, getSlides, loadPresentation, renderSlideToSvg,
} from './vendor/office-kit-pptx-0.21.0.mjs';

const limits = {
  maxEntries: 10000,
  maxTotalUncompressedBytes: 64 * 1024 * 1024,
  maxXmlPartBytes: 8 * 1024 * 1024,
  maxTotalXmlBytes: 32 * 1024 * 1024,
};
const maxSlideCount = 500;
const maxRenderedLength = 32 * 1024 * 1024;
const emuPerInch = 914400;

self.onmessage = async ({ data: { bytes } }) => {
  try {
    const presentation = await loadPresentation(bytes, { limits });
    const slides = getSlides(presentation);
    if (!slides.length || slides.length > maxSlideCount) throw new Error('Unsupported slide count');
    const { width, height } = getSlideSize(presentation);
    const widthMils = Math.round(width * 1000 / emuPerInch);
    const heightMils = Math.round(height * 1000 / emuPerInch);
    if (![widthMils, heightMils].every(value => Number.isInteger(value) && value >= 1000 && value <= 40000)) {
      throw new Error('Unsupported slide dimensions');
    }
    const canvas = typeof OffscreenCanvas === 'function' ? new OffscreenCanvas(1, 1).getContext('2d') : null;
    const measureText = canvas ? (text, font) => {
      const family = font.family.replace(/["\\]/g, '');
      canvas.font = `${font.italic ? 'italic ' : ''}${font.bold ? 'bold ' : ''}${font.sizePx}px "${family}", sans-serif`;
      const metrics = canvas.measureText(text);
      return {
        widthPx: metrics.width + Math.max(0, [...text].length - 1) * font.letterSpacingPx,
        ascentPx: metrics.fontBoundingBoxAscent,
        descentPx: metrics.fontBoundingBoxDescent,
      };
    } : undefined;
    const options = { textLayout: 'svg', measureText, resolveFamily: font => font ?? 'Arial' };
    let total = 0;
    const images = slides.map(slide => {
      const svg = renderSlideToSvg(presentation, slide, options);
      total += svg.length;
      if (total > maxRenderedLength) throw new Error('Slides are too large to display');
      return svg;
    });
    self.postMessage({ images, widthMils, heightMils });
  } catch (error) {
    self.postMessage({ error: 'Error', message: error.message });
  }
};
