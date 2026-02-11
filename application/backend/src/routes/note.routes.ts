import { Router } from "express";
import { NoteController } from "../controller/note.controller"

const router = Router();
const controller = new NoteController();


router.get("/", (req, res) => controller.getAll(req, res));
router.get("/:name", (req, res) => controller.getByName(req, res));
router.post("/", (req, res) => controller.create(req, res));
router.put("/:name", (req, res) => controller.update(req, res)); 
router.delete("/:name", (req, res) => controller.delete(req, res));

export default router;